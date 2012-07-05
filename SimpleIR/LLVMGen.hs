-- Copyright (c) 2012 Eric McCorkle.  All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
-- 3. Neither the name of the author nor the names of any contributors
--    may be used to endorse or promote products derived from this software
--    without specific prior written permission.
--
-- THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS ``AS IS''
-- AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
-- TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
-- PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS
-- OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
-- SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
-- LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
-- USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
-- ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
-- OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
-- OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
-- SUCH DAMAGE.

-- | This module implements compilation of SimpleIR to LLVM.  Roughly
-- speaking, the process goes something like this:
--
-- 1) Convert all named types to LLVM types
-- 2) Generate metadata for generated GC types
-- 3) Generate declarations for all necessary accessors and modifiers
-- for GC types.
-- 4) Generate declarations for all globals, and convert their types.
-- 5) Compute dominance frontiers, and from that, phi-sets for each
-- function.
-- 6) Generate code for all functions.
--
-- What isn't implemented:
--   * Escape analysis to figure out what needs to be alloca'ed
--   * Storing local variables in alloca'ed slots at all
--
-- Notes:
--   * For aggregates-as-values, insert a value in the value map
--     during final code generation describing the aggregate, and
--     mapping its fields to new values.  For phis, treat an
--     assignment to an aggregate as an assignment to all of its
--     fields.  Do this field expansion BEFORE creating the phi-sets
--   * Variants can be treated like any other aggregate.  Anytime we
--     assign a particular variant to a variant typed value, set all
--     the fields for the other variants to undef.
--   * Local variables should probably be annotated with a source.
--     This would allow static link accessed variables to be bound
--     properly.
--   * Functions could take an additional argument list representing
--     static linking.
module SimpleIR.LLVMGen(
       toLLVM
       ) where

import Data.Array(Array)
import Data.Array.IArray
import Data.Array.IO
import Data.Array.Unboxed(UArray)
import Data.BitArray.IO
import Data.Foldable
import Data.Graph.Inductive.Graph
import Data.Graph.Inductive.Query.DFS
import Data.Graph.Inductive.Query.DomFrontier
import Data.Map(Map)
import Data.Maybe
import Data.Traversable
import Data.Tree
import Data.Word
import Foreign.Ptr
import Prelude hiding (mapM_, mapM, foldr, foldl, sequence)
import SimpleIR

import qualified Data.Map as Map
import qualified LLVM.BitWriter as LLVM
import qualified LLVM.Core as LLVM
import qualified SimpleIR.LLVMGen.ConstValue as ConstValue

constant :: Bool -> Mutability -> Bool
constant _ Immutable = True
constant True _ = True
constant _ _ = False

-- | Generate LLVM IR from the SimpleIR module.
toLLVM :: Graph gr => Module gr -> IO LLVM.ModuleRef
toLLVM mod @ (Module { modName = name, modTypes = types, modGlobals = globals,
                       modGCHeaders = gcheaders, modGenGCs = gengcs }) =
  let
    -- First thing: run through all the named types, and generate
    -- LLVM.TypeRefs for all of them
    genTypeDefs :: LLVM.ContextRef -> IO (UArray Typename LLVM.TypeRef)
    genTypeDefs ctx =
      let
        -- Fill in the array of types
        initTypeArray :: IOUArray Typename LLVM.TypeRef -> IO ()
        initTypeArray typemap =
          let
            -- Translate a SimpleIR type into an LLVM type.  We need
            -- the map from typenames to (uninitialized) LLVM types to
            -- do this.
            genLLVMType :: Type -> IO LLVM.TypeRef
            genLLVMType (StructType packed fields) =
              do
                fieldtys <- mapM (\(_, _, ty) -> genLLVMType ty) (elems fields)
                LLVM.structTypeInContext ctx fieldtys packed
            genLLVMType (ArrayType (Just size) inner) =
              do
                inner <- genLLVMType inner
                return (LLVM.arrayType inner size)
            genLLVMType (ArrayType Nothing inner) =
              do
                inner <- genLLVMType inner
                return (LLVM.arrayType inner 0)
            genLLVMType (PtrType (BasicObj inner)) =
              do
                inner <- genLLVMType inner
                return (LLVM.pointerType inner 0)
            genLLVMType (PtrType (GCObj _ id)) =
              let
                (tname, _, _) = gcheaders ! id
              in do
                innerty <- updateEntry tname
                return (LLVM.pointerType innerty 0)
            genLLVMType (IdType id) = updateEntry id
            genLLVMType (IntType _ 1) = LLVM.int1TypeInContext ctx
            genLLVMType (IntType _ 8) = LLVM.int8TypeInContext ctx
            genLLVMType (IntType _ 16) = LLVM.int16TypeInContext ctx
            genLLVMType (IntType _ 32) = LLVM.int32TypeInContext ctx
            genLLVMType (IntType _ 64) = LLVM.int64TypeInContext ctx
            genLLVMType (IntType _ size) = LLVM.intTypeInContext ctx size
            genLLVMType (FloatType 32) = LLVM.floatTypeInContext ctx
            genLLVMType (FloatType 64) = LLVM.doubleTypeInContext ctx
            genLLVMType (FloatType 128) = LLVM.fp128TypeInContext ctx

            -- Grab the type entry for this type name, possibly
            -- (re)initializing it
            updateEntry :: Typename -> IO LLVM.TypeRef
            updateEntry ind =
              case types ! ind of
                (_, Just ty @ (StructType packed fields)) ->
                  do
                    ent <- readArray typemap ind
                    if LLVM.isOpaqueStruct ent
                      then do
                        fieldtys <- mapM (\(_, _, ty) -> genLLVMType ty)
                                         (elems fields)
                        LLVM.structSetBody ent fieldtys packed
                        return ent
                      else return ent
                (_, Just ty) ->
                  do
                    ent <- readArray typemap ind
                    if ent == nullPtr
                      then do
                        newty <- genLLVMType ty
                        writeArray typemap ind newty
                        return ent
                      else return ent
                _ -> readArray typemap ind
          in
            mapM_ (\ind -> updateEntry ind >> return ()) (indices types)

        -- Initialize structures and opaques to empty named structures and
        -- everything else to null pointers.
        initEntry :: (String, Maybe Type) -> IO LLVM.TypeRef
        initEntry (str, Nothing) =
          LLVM.structCreateNamed ctx str
        initEntry (str, Just (StructType _ _)) =
          LLVM.structCreateNamed ctx str
        initEntry _ = return nullPtr
      in do
        elems <- mapM initEntry (elems types)
        typearr <- newListArray (bounds types) elems
        initTypeArray typearr
        unsafeFreeze typearr

    -- Generate an array mapping GCHeaders to llvm globals
    gcHeaders :: LLVM.ModuleRef -> LLVM.ContextRef ->
                 UArray Typename LLVM.TypeRef ->
                 IO (Array GCHeader LLVM.ValueRef)
    gcHeaders mod ctx typemap =
      let
        mobilityStr Mobile = "mobile"
        mobilityStr Immobile = "immobile"

        mutabilityStr Immutable = "const"
        mutabilityStr WriteOnce = "writeonce"
        mutabilityStr Mutable = "mutable"
        mutabilityStr (Custom str) = str

        mapfun :: LLVM.TypeRef -> (Typename, Mobility, Mutability) ->
                  IO LLVM.ValueRef
        mapfun hdrty (tname, mob, mut) =
          let
            (str, _) = types ! tname
            name = "core.gc.typedesc." ++ str ++ "." ++
              mobilityStr mob ++ "." ++ mutabilityStr mut
          in do
            val <- LLVM.addGlobal mod hdrty name
            LLVM.setGlobalConstant val True
            LLVM.setLinkage val LLVM.LinkerPrivateLinkage
            return val
      in do
        hdrty <- LLVM.structCreateNamed ctx "core.gc.typedesc"
        mapM (mapfun hdrty) gcheaders

    -- Run over all the global values, and generate declarations for
    -- them all.
    genDecl :: Graph gr => LLVM.ModuleRef -> LLVM.ContextRef ->
                           UArray Typename LLVM.TypeRef -> Global gr ->
                           IO LLVM.ValueRef
    genDecl mod ctx typedefs (Function { funcName = name, funcRetTy = resty,
                                         funcParams = args,
                                         funcValTys = scope }) =
      do
        argtys <- mapM (toLLVMType ctx typedefs . (!) scope) args
        resty <- toLLVMType ctx typedefs resty
        LLVM.addFunction mod name (LLVM.functionType resty argtys False)
    genDecl mod ctx typedefs (GlobalVar { gvarName = name, gvarTy = ty }) =
      do
        llvmty <- toLLVMType ctx typedefs ty
        LLVM.addGlobal mod llvmty name

    -- Generate the accessors and modifiers for the given type
    genAccModDecls :: LLVM.ModuleRef -> LLVM.ContextRef ->
                      UArray Typename LLVM.TypeRef -> IO ()
    genAccModDecls mod ctx typedefs =
      let
        genAccMods :: (Typename, (String, Maybe Type)) -> IO ()
        genAccMods (typename, (str, Just ty)) =
          let
            tyref = (typedefs ! typename)

            genDecls :: Bool -> Type -> String -> [LLVM.TypeRef] -> IO ()
            genDecls const ty name args =
              let
                readtype :: LLVM.TypeRef -> LLVM.TypeRef
                readtype resty = LLVM.functionType resty (reverse args) False

                writetype :: LLVM.TypeRef -> LLVM.TypeRef
                writetype resty =
                  LLVM.functionType LLVM.voidType (reverse (resty : args)) False
              in do
                resty <- toLLVMType ctx typedefs ty
                readfunc <- LLVM.addFunction mod (name ++ ".read")
                                                 (readtype resty)
                LLVM.addFunctionAttr readfunc LLVM.NoUnwindAttribute
                LLVM.addFunctionAttr readfunc LLVM.ReadOnlyAttribute
                LLVM.addFunctionAttr readfunc LLVM.AlwaysInlineAttribute
                if not const
                  then do
                    writefunc <- LLVM.addFunction mod (name ++ ".write")
                                                      (writetype resty)
                    LLVM.addFunctionAttr writefunc LLVM.NoUnwindAttribute
                    LLVM.addFunctionAttr writefunc LLVM.AlwaysInlineAttribute
                    return()
                  else return ()

            genAccMods' :: String -> Bool -> [LLVM.TypeRef] ->
                           (String, Mutability, Type) -> IO ()
            genAccMods' prefix const args (name, mut, StructType _ fields) =
              do
                mapM_ (genAccMods' (prefix ++ "." ++ name)
                                   (constant const mut) args) fields
            genAccMods' prefix const args (name, mut, ArrayType _ inner) =
              do
                genAccMods' prefix const (LLVM.int32Type : args)
                                         (name, mut, inner)
            genAccMods' prefix const args (name, mut, ty) =
              genDecls (constant const mut) ty (prefix ++ "." ++ name) args
          in do
            genAccMods' "core.types" False [tyref] (str, Mutable, ty)
            return ()
        genAccMods _ = return ()
      in
        mapM_ genAccMods (assocs types)

    -- Actually generate the definitions for all globals
    genDefs :: LLVM.ContextRef -> Array Globalname LLVM.ValueRef ->
               UArray Typename LLVM.TypeRef -> IO ()
    genDefs ctx decls typedefs =
      let
        genConst = ConstValue.genConst mod ctx typedefs decls

        -- Add a definition to a global.  This function does all the
        -- real work
        addDef :: Graph gr =>
                  LLVM.BuilderRef -> (Globalname, Global gr) -> IO ()
        -- Globals are pretty simple, generate the initializer and set
        -- it for the variable
        addDef _ (gname, GlobalVar { gvarName = name, gvarInit = Just exp }) =
          do
            (init, _) <- genConst exp
            LLVM.setInitializer (decls ! gname) init
        addDef builder
               (gname, Function { funcBody = Just (Body (Label entry) graph),
                                  funcValTys = valtys, funcParams = params }) =
          let
            func = (decls ! gname)
            [dfstree] = dff [entry] graph
            dfsnodes @ (entrynode : _) = foldr (:) [] dfstree
            range @ (startnode, endnode) = nodeRange graph
            nodelist = nodes graph
            (Id startid, Id endid) = bounds valtys
            valids = indices valtys

            -- First, map each CFG block to an LLVM basic block
            genBlocks :: IO (UArray Node LLVM.BasicBlockRef)
            genBlocks =
              let
                genBlock :: Node -> IO (Node, LLVM.BasicBlockRef)
                genBlock node =
                  do
                    block <- LLVM.appendBasicBlockInContext ctx func
                                                            ("L" ++ show node)
                    return (node, block)
              in do
                vals <- mapM genBlock nodelist
                return (array range vals)

            -- Build the sets of phi-values for each basic block
            buildPhiSets :: IO [(Node, [Id])]
            buildPhiSets =
              let
                domfronts' = domFrontiers graph entry

                domfronts :: Array Node [Node]
                domfronts = array range domfronts'

                getIndex :: Node -> Id -> Int
                getIndex node (Id id) =
                  let
                    node' = node - startnode
                    id' = (fromIntegral id) - (fromIntegral startid)
                    span = (fromIntegral endid) - (fromIntegral startid) + 1
                  in
                    (node' * span) + id'

                -- Add id to the phi-set for node
                addPhi :: IOBitArray -> Node -> Id -> IO ()
                addPhi arr node id =
                  let
                    domset = domfronts ! node
                    appfun node = writeBit arr (getIndex node id) True
                  in
                    mapM_ appfun domset

                -- Translate the bit array into a list of ids
                getPhiSet :: IOBitArray -> Node -> IO (Node, [Id])
                getPhiSet sets node =
                  let
                    foldfun :: [Id] -> Id -> IO [Id]
                    foldfun phiset id =
                      do
                        bit <- readBit sets (getIndex node id)
                        if bit
                          then return (id : phiset)
                          else return phiset
                  in do
                    front <- foldlM foldfun [] valids
                    return (node, front)

                -- Run through a node, add anything it modifies to the
                -- the phi-set of each node in its dominance frontier.
                buildPhiSet :: IOBitArray -> Node -> IO ()
                buildPhiSet modset node =
                  let
                    Just (Block stms _) = lab graph node

                    appfun (Move (Var id) _) = addPhi modset node id
                    appfun _ = return ()
                  in do
                    mapM_ appfun stms
              in do
                sets <- newBitArray ((getIndex startnode (Id startid)),
                                     (getIndex endnode (Id endid))) False
                mapM_ (buildPhiSet sets) nodelist
                mapM (getPhiSet sets) nodelist

            -- Generate the phi instructions required by a phi-set,
            -- add them to a phi-map array.
            genPhis :: UArray Node LLVM.BasicBlockRef ->
                       Array Id LLVM.TypeRef -> [(Node, [Id])] ->
                       IO (Array Node [(Id, LLVM.ValueRef)])
            genPhis blocks tyarr phiset =
              let
                mapblocks :: (Node, [Id]) -> IO (Node, [(Id, LLVM.ValueRef)])
                mapblocks (node, ids) =
                  let
                    mapvars :: Id -> IO (Id, LLVM.ValueRef)
                    mapvars id =
                      do
                        phi <- LLVM.buildPhi builder (tyarr ! id) ""
                        return (id, phi)                    
                  in do
                    LLVM.positionAtEnd builder (blocks ! node)
                    phis <- mapM mapvars ids
                    return (node, phis)
              in do
                vals <- mapM mapblocks phiset
                return (array (bounds blocks) vals)

            -- The initial value map contains just the arguments,
            -- and undefs for everything else.
            initValMap :: LLVM.BuilderRef -> IO (Word, ValMap)
            initValMap builder =
              let
                -- Add arguments to the value map
                addArg :: (Word, ValMap) -> (Int, Id) -> IO (Word, ValMap)
                addArg vmap (arg, id @ (Id ind)) =
                  let
                    paramty = valtys ! id
                    param = LLVM.getParam func arg

                    getArgVal :: LLVM.ValueRef -> Type -> (Word, ValMap) ->
                                 IO (Location, Word, ValMap)
                    getArgVal baseval (StructType _ fields) vmap =
                      let
                        foldfun (vmap, inds) (Fieldname field,
                                              (_, _, fieldty)) =
                          do
                            newbase <- LLVM.buildExtractValue builder
                                       baseval field ""
                            (loc, newind, valmap) <-
                              getArgVal newbase fieldty vmap
                            return ((newind + 1, Map.insert newind loc valmap),
                                    newind : inds)
                      in do
                        ((newind, valmap), fieldlist) <-
                          foldlM foldfun (vmap, []) (assocs fields)
                        return (Struct (listArray (bounds fields)
                                                  (reverse fieldlist)),
                                newind, valmap)
                    getArgVal baseval _ (newind, valmap) =
                      return (Local baseval, newind, valmap)
                  in do
                    (loc, newind, valmap) <- getArgVal param paramty vmap
                    return (newind, Map.insert ind loc valmap)

                getVal :: Type -> (Word, ValMap) -> IO (Location, Word, ValMap)
                getVal (StructType _ fields) vmap =
                  let
                    foldfun (vmap, inds) (Fieldname field, (_, _, fieldty)) =
                      do
                        (loc, newind, valmap) <- getVal fieldty vmap
                        return ((newind + 1, Map.insert newind loc valmap),
                                newind : inds)

                  in do
                    ((newind, valmap), fieldlist) <-
                      foldlM foldfun (vmap, []) (assocs fields)
                    return (Struct (listArray (bounds fields)
                                              (reverse fieldlist)),
                            newind, valmap)
                getVal ty (newind, valmap) =
                  do
                    ty' <- toLLVMType ctx typedefs ty
                    return (Local (LLVM.getUndef ty'), newind, valmap)

                -- Add undef values in for everything else
                addUndef :: (Word, ValMap) -> Id -> IO (Word, ValMap)
                addUndef vmap @ (_, valmap) id @ (Id ind) =
                  case Map.lookup ind valmap of
                    Just val -> return vmap
                    Nothing ->
                      do
                        (loc, newind, valmap) <- getVal (valtys ! id) vmap
                        return (newind, Map.insert ind loc valmap)

                (_, Id maxval) = bounds valtys
                init = (maxval + 1, Map.empty)
                arginds = zip [0..length params] params
              in do
                withArgs <- foldlM addArg init arginds
                foldlM addUndef withArgs (indices valtys)

            -- Generate the instructions for a basic block
            genInstrs :: UArray Node LLVM.BasicBlockRef ->
                         Array Node [(Id, LLVM.ValueRef)] ->
                         Array Id LLVM.TypeRef -> LLVM.BasicBlockRef ->
                         LLVM.BuilderRef -> ValMap -> IO ()
            genInstrs blocks phiarr tyarr entryblock builder valmap =
              let
                -- Take the value map, and add the incoming edges to a
                -- successor block.  Called when leaving a block on
                -- all its successors.
                bindPhis :: LLVM.BasicBlockRef -> ValMap -> Node -> IO ()
                bindPhis from valmap to =
                  let
                    phis = phiarr ! to
                    fromval = LLVM.basicBlockAsValue from

                    bindPhi :: (Id, LLVM.ValueRef) -> IO ()
                    bindPhi (Id ind, phival) =
                      let
                        Just (Local oldval) = Map.lookup ind valmap
                      in do
                        LLVM.addIncoming phival [(oldval, fromval)]
                  in
                    mapM_ bindPhi phis

                -- Replace all values with corresponding phis when
                -- entering a block.
                addPhiVals :: Node -> ValMap -> ValMap
                addPhiVals node valmap =
                  let
                    phis = phiarr ! node

                    addPhi :: (Id, LLVM.ValueRef) -> ValMap -> ValMap
                    addPhi (Id ind, phival) = Map.insert ind (Local phival)
                  in do
                    foldr addPhi valmap phis

                -- Traverse the CFG.  This takes a DFS tree as an argument.
                traverse :: LLVM.BasicBlockRef -> ValMap -> Tree Node -> IO ()
                traverse from invalmap (Node { rootLabel = curr,
                                               subForest = nexts }) =
                  let
                    valmap = addPhiVals curr invalmap
                    Just (Block stms trans) = lab graph curr
                    currblock = blocks ! curr
                    outs = suc graph curr
                  in do
                    LLVM.positionAtEnd builder currblock
                    valmap <- foldlM genStm valmap stms
                    genTransfer valmap trans
                    mapM_ (bindPhis currblock valmap) outs
                    mapM_ (traverse currblock valmap) nexts
              in do
                bindPhis entryblock valmap entrynode
                traverse entryblock valmap dfstree
          in do
            tyarr <- mapM (toLLVMType ctx typedefs) valtys
            entryblock <- LLVM.appendBasicBlockInContext ctx func "entry"
            blocks <- genBlocks
            LLVM.positionAtEnd builder entryblock
            (numvals, valmap) <- initValMap builder
            LLVM.buildBr builder (blocks ! entrynode)
            phiset <- buildPhiSets
            phiarr <- genPhis blocks tyarr phiset
            genInstrs blocks phiarr tyarr entryblock builder valmap
      in do
        builder <- LLVM.createBuilderInContext ctx
        mapM_ (addDef builder) (assocs globals)
  in do
    mod <- LLVM.moduleCreateWithName name
    ctx <- LLVM.getModuleContext mod
    typedefs <- genTypeDefs ctx
    gcheaderdecls <- gcHeaders mod ctx typedefs
    genMetadata mod ctx
    decls <- mapM (genDecl mod ctx typedefs) globals
    genAccModDecls mod ctx typedefs
    genDefs ctx decls typedefs
    return mod