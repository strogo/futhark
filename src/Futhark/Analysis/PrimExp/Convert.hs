{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Converting back and forth between 'PrimExp's.
module Futhark.Analysis.PrimExp.Convert
  (
    primExpToExp
  , primExpFromExp
  , primExpFromSubExp
  , substituteInPrimExp

    -- * Module reexport
    , module Futhark.Analysis.PrimExp
  ) where

import           Control.Applicative

import           Prelude
import qualified Data.Map.Strict as M
import           Data.Maybe

import           Futhark.Analysis.PrimExp
import           Futhark.Construct
import           Futhark.Representation.AST

-- | Convert a 'PrimExp' to a Futhark expression.  The provided
-- function converts the leaves.
primExpToExp :: MonadBinder m =>
                (v -> m (Exp (Lore m))) -> PrimExp v -> m (Exp (Lore m))
primExpToExp f (BinOpExp op x y) =
  BasicOp <$> (BinOp op
               <$> primExpToSubExp "binop_x" f x
               <*> primExpToSubExp "binop_y" f y)
primExpToExp f (CmpOpExp op x y) =
  BasicOp <$> (CmpOp op
               <$> primExpToSubExp "cmpop_x" f x
               <*> primExpToSubExp "cmpop_y" f y)
primExpToExp f (UnOpExp op x) =
  BasicOp <$> (UnOp op <$> primExpToSubExp "unop_x" f x)
primExpToExp f (ConvOpExp op x) =
  BasicOp <$> (ConvOp op <$> primExpToSubExp "convop_x" f x)
primExpToExp _ (ValueExp v) =
  return $ BasicOp $ SubExp $ Constant v
primExpToExp f (LeafExp v _) =
  f v

instance ToExp v => ToExp (PrimExp v) where
  toExp = primExpToExp toExp

primExpToSubExp :: MonadBinder m =>
                   String -> (v -> m (Exp (Lore m))) -> PrimExp v -> m SubExp
primExpToSubExp s f e = letSubExp s =<< primExpToExp f e

-- | Convert an expression to a 'PrimExp'.  The provided function is
-- used to convert expressions that are not trivially 'PrimExp's.
-- This includes constants and variable names, which are passed as
-- 'SubExp's.
primExpFromExp :: Monad m =>
                  (Exp lore -> m (PrimExp v)) -> Exp lore -> m (PrimExp v)
primExpFromExp f (BasicOp (BinOp op x y)) =
  BinOpExp op <$> primExpFromSubExpM f x <*> primExpFromSubExpM f y
primExpFromExp f (BasicOp (CmpOp op x y)) =
  CmpOpExp op <$> primExpFromSubExpM f x <*> primExpFromSubExpM f y
primExpFromExp f (BasicOp (UnOp op x)) =
  UnOpExp op <$> primExpFromSubExpM f x
primExpFromExp f (BasicOp (ConvOp op x)) =
  ConvOpExp op <$> primExpFromSubExpM f x
primExpFromExp _ (BasicOp (SubExp (Constant v))) =
  return $ ValueExp v
primExpFromExp f e = f e

primExpFromSubExpM :: Monad m =>
                     (Exp lore -> m (PrimExp v)) -> SubExp -> m (PrimExp v)
primExpFromSubExpM f = primExpFromExp f . BasicOp . SubExp

-- | Convert 'SubExp's of a given type.
primExpFromSubExp :: PrimType -> SubExp -> PrimExp VName
primExpFromSubExp t (Var v)      = LeafExp v t
primExpFromSubExp _ (Constant v) = ValueExp v

-- | Substituting names in a PrimExp with other PrimExps
substituteInPrimExp :: Ord v => M.Map v (PrimExp v)
                    -> PrimExp v -> PrimExp v
substituteInPrimExp tab pexp@(LeafExp v _) =
    fromMaybe pexp $ M.lookup v tab
substituteInPrimExp _ pexp@(ValueExp _) = pexp
substituteInPrimExp tab (BinOpExp bop pe1 pe2) =
    BinOpExp bop (substituteInPrimExp tab pe1)
                 (substituteInPrimExp tab pe2)
substituteInPrimExp tab (CmpOpExp cop pe1 pe2) =
    CmpOpExp cop (substituteInPrimExp tab pe1)
                 (substituteInPrimExp tab pe2)
substituteInPrimExp tab (UnOpExp uop pe) =
    UnOpExp uop $ substituteInPrimExp tab pe
substituteInPrimExp tab (ConvOpExp cop pe) =
    ConvOpExp cop $ substituteInPrimExp tab pe
