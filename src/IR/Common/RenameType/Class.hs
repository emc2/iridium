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
{-# OPTIONS_GHC -Wall -Werror #-}
{-# LANGUAGE MultiParamTypeClasses, FlexibleInstances #-}

-- | This module defines a class for things that can have their types
-- alpha-renamed.
module IR.Common.RenameType.Class(
       RenameType(..)
       ) where

import Data.Array.IArray(IArray, Ix)

import qualified Data.Array.IArray as IArray

-- | Class of things that can have their types alpha-renamed.
class RenameType typename syntax where
  -- | Rename all typenames in the given syntax construct.
  renameType :: (typename -> typename)
             -- ^ A function which renames typenames.
             -> syntax
             -- ^ The syntax construct to rename.
             -> syntax
             -- ^ The input, with the renaming function applied to all
             -- typenames.

instance (RenameType id syntax) => RenameType id (Maybe syntax) where
  renameType f (Just t) = Just (renameType f t)
  renameType _ Nothing = Nothing

instance (RenameType id syntax) => RenameType id [syntax] where
  renameType f = map (renameType f)

instance (RenameType id syntax, Ix idx, IArray arr syntax) =>
         RenameType id (arr idx syntax) where
  renameType f = IArray.amap (renameType f)
