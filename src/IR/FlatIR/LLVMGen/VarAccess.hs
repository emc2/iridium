-- Copyright (c) 2015 Eric McCorkle.  All rights reserved.
--
-- Redistribution and use in source and binary forms, with or without
-- modification, are permitted provided that the following conditions
-- are met:
--
-- 1. Redistributions of source code must retain the above copyright
--    notice, this list of conditions and the following disclaimer.
--
-- 2. Redistributions in binary form must reproduce the above copyright
--    notice, this list of conditions and the following disclaimer in the
--    documentation and/or other materials provided with the distribution.
--
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
{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}

-- | This module implements tools for compiling variable reads and
-- writes.
module IR.FlatIR.LLVMGen.VarAccess(
       -- * Types
       Location(..),
       Index(..),
       Access(..),
       ValMap,

       -- * ValMap functions
       getVarLocation,

       -- * Indexing instruction generators
       genGEP,
       genExtractValue,

       -- * Access generators
       genVarAddr,
       genVarRead,
       genWrite
       ) where

import Data.Array.IArray
import Data.Array.Unboxed(UArray)
import Data.Foldable
import Data.Map(Map)
import Data.Maybe
import Data.Traversable
import Data.Word
import IR.FlatIR.Syntax
import IR.FlatIR.LLVMGen.LLVMValue
import IR.FlatIR.LLVMGen.MemAccess

import Prelude hiding (mapM_, mapM, foldr, foldl, sequence)

import qualified Data.Map as Map
import qualified LLVM.Core as LLVM

-- | Locations are stored in ValMaps to indicate how a given variable
-- is represented.
data Location =
  -- | A variable stored in an SSA binding
    BindLoc !LLVM.ValueRef
  -- | A variable stored in a memory location
  | MemLoc Type !Mutability !LLVM.ValueRef
  -- | A structure, which refers to other local variables
  | StructLoc !(UArray Fieldname Word)

-- | This is a type used to store indexes for constructing
-- getelementptr and extractvalue instructions
data Index =
  -- | A field index.  We keep the field name, so we can index into
  -- structure types and locations.
    FieldInd !Fieldname
  -- | A value.  These should only exist when indexing into an array.
  | ValueInd !LLVM.ValueRef

-- | Accesses represent a slightly more complex value type.  These are
-- essentially the dual of Locations, and are paired up with them in
-- genVarWrite to implement writes.
data Access =
  -- | An LLVM value
    DirectAcc !LLVM.ValueRef
  -- | Equivalent to a structure constant.
  | StructAcc (Array Fieldname Access)

-- | A map from Ids to locations, representing the state of the
-- program.
type ValMap = Map Word Location

-- | Generate a getelementptr instruction from the necessary information
genGEP :: LLVM.BuilderRef -> LLVM.ValueRef -> [Index] -> IO LLVM.ValueRef
genGEP _ val [] = return val
genGEP builder val indexes = LLVM.buildGEP builder val (map toValue indexes) ""

-- | Generate an extractvalue instruction from the necessary information
genExtractValue :: LLVM.BuilderRef -> Access -> [Index] -> IO Access
genExtractValue _ acc [] = return acc
genExtractValue builder (DirectAcc val) indexes =
  let
    genExtractValue' val' (FieldInd (Fieldname fname) : indexes') =
      do
        inner' <- genExtractValue' val' indexes'
        LLVM.buildExtractValue builder inner' fname ""
    genExtractValue' _ (ValueInd _ : _) =
      error "Value index cannot occur in extractvalue"
    genExtractValue' val' [] = return val'
  in do
    out <- genExtractValue' val indexes
    return (DirectAcc out)
genExtractValue builder (StructAcc fields) (FieldInd field : indexes) =
  genExtractValue builder (fields ! field) indexes
genExtractValue _ acc ind =
  error ("Mismatched access " ++ show acc ++ " and index " ++ show ind)

-- | Lookup a variable in a value map and return its location
getVarLocation :: ValMap -> Id -> Location
getVarLocation valmap (Id ind) =
  fromJust (Map.lookup ind valmap)

-- | Get the address of a variable, as well as its mutability
genVarAddr :: LLVM.BuilderRef -> ValMap -> [Index] -> Id ->
              IO (LLVM.ValueRef, Mutability)
genVarAddr builder valmap indexes var =
  case getVarLocation valmap var of
    MemLoc _ mut addr ->
      do
        out <- genGEP builder addr indexes
        return (out, mut)
    _ -> error ("Location has no address")

-- | Generate an access to the given variable, with the given indexes.
genVarRead :: LLVM.ContextRef -> LLVM.BuilderRef -> ValMap -> [Index] -> Id ->
              IO Access
genVarRead ctx builder valmap indexes var =
  case getVarLocation valmap var of
    -- Straightforward, it's a value.  Make sure we have no indexes
    -- and return the value.
    BindLoc val ->
      case indexes of
        [] -> return (DirectAcc val)
        _ -> error "Indexes in read of non-aggregate variable"
    -- For a memory location, generate a GEP, then load, then build a
    -- direct access.
    MemLoc ty mut mem ->
      do
        addr <- genGEP builder mem indexes
        val <- genLoad ctx builder addr mut ty
        return (DirectAcc val)
    -- For structures, we'll either recurse, or else build a structure
    -- access.
    StructLoc fields ->
      case indexes of
        -- If there's indexes, recurse
        (FieldInd ind : indexes') ->
          genVarRead ctx builder valmap indexes' (Id (fields ! ind))
        -- Otherwise, build a structure access
        [] ->
          do
            accs <- mapM (genVarRead ctx builder valmap [])
                         (map Id (elems fields))
            return (StructAcc (listArray (bounds fields) accs))
        _ -> error "Wrong kind of index for a structure location"

-- | This function handles writes to variables without indexes
genRawVarWrite :: LLVM.ContextRef -> LLVM.BuilderRef ->
                  ValMap -> Access -> Id -> IO ValMap
genRawVarWrite ctx builder valmap acc var @ (Id name) =
  case getVarLocation valmap var of
    BindLoc _ -> return (Map.insert name (BindLoc (toValue acc)) valmap)
    loc -> genRawWrite ctx builder valmap acc loc

-- | This function handles writes to non-variables without indexes
genRawWrite :: LLVM.ContextRef -> LLVM.BuilderRef -> ValMap ->
               Access -> Location -> IO ValMap
-- We've got a value and a memory location.  Generate a store.
genRawWrite ctx builder valmap acc (MemLoc ty mut addr) =
  do
    genStore ctx builder (toValue acc) addr mut ty
    return valmap
-- For structures, we end up recursing.
genRawWrite ctx builder valmap acc (StructLoc fields) =
  case acc of
    -- We've got a value (which ought to have a structure type),
    -- and a local variable that's a structure.  Go through and
    -- generate writes into each field.
    DirectAcc val ->
      let
        foldfun valmap' (Fieldname fname, var) =
          do
            val' <- LLVM.buildExtractValue builder val fname ""
            genRawVarWrite ctx builder valmap' (DirectAcc val') (Id var)
      in do
        foldlM foldfun valmap (assocs fields)
    -- We've got a structure access and a structure location, which
    -- should match up.  Pair up the fields and recurse on each pair
    -- individually.
    StructAcc accfields ->
      let
        foldfun valmap' (acc', var) =
          genRawVarWrite ctx builder valmap' acc' (Id var)
        fieldlist = zip (elems accfields) (elems fields)
      in
        foldlM foldfun valmap fieldlist
genRawWrite _ _ _ _ (BindLoc _) = error "genRawWrite can't handle BindLocs"

-- | Take an access, a non-variable location, and a list of indexes, and
-- do the work to write to the location.  This involves many possible
-- cases.
genWrite :: LLVM.ContextRef -> LLVM.BuilderRef -> ValMap ->
            Access -> [Index] -> Location -> IO ValMap
-- This case should never happen
genWrite _ _ _ _ _ (BindLoc _) = error "genWrite can't handle BindLocs"
-- For no index cases, pass off to genRawWrite
genWrite ctx builder valmap acc [] loc =
  genRawWrite ctx builder valmap acc loc
-- We've got a value and a memory location.  Generate a GEP and store
-- the value.
genWrite ctx builder valmap acc indexes (MemLoc ty mut mem) =
  do
    addr <- LLVM.buildGEP builder mem (map toValue indexes) ""
    genStore ctx builder (toValue acc) addr mut ty
    return valmap
-- For structures, we recurse to strip away the fields
genWrite ctx builder valmap acc (FieldInd field : indexes) (StructLoc fields) =
  genVarWrite ctx builder valmap acc indexes (Id (fields ! field))
-- Any other kind of index is an error condition
genWrite _ _ _ _ _ (StructLoc _) = error "Bad indexes in assignment to variable"

-- | Take an access, a variable name, and a list of indexes and do the
-- work to write to the location.
genVarWrite :: LLVM.ContextRef -> LLVM.BuilderRef -> ValMap ->
               Access -> [Index] -> Id -> IO ValMap
genVarWrite ctx builder valmap acc indexes var =
  case getVarLocation valmap var of
    BindLoc _ ->
      case indexes of
        [] -> genRawVarWrite ctx builder valmap acc var
        _ -> error "Extra indexes in write to variable"
    loc -> genWrite ctx builder valmap acc indexes loc

instance LLVMValue Index where
  toValue (FieldInd fname) = toValue fname
  toValue (ValueInd val) = val

instance LLVMValue Access where
  toValue (DirectAcc val) = val
  toValue (StructAcc arr) = LLVM.constStruct (map toValue (elems arr)) False

instance Show Index where
  show (FieldInd (Fieldname fname)) = "field " ++ show fname
  show (ValueInd _) = "value"

instance Show Access where
  show (DirectAcc _) = "direct"
  show (StructAcc _) = "struct"
