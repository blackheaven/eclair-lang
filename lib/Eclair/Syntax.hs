{-# LANGUAGE TemplateHaskell #-}

module Eclair.Syntax
  ( AST(..)
  , _Lit
  , _Var
  , _Atom
  , _Rule
  , _Module
  , Value
  , SearchClause
  , Decl
  , Number
  , Id(..)
  , appendToId
  , scc
  ) where

import Control.Lens
import Protolude
import qualified Data.Graph as G
import qualified Data.Map as M
import Protolude.Unsafe (unsafeFromJust)


type Number = Int

newtype Id = Id Text
  deriving (Eq, Ord, Show)

appendToId :: Id -> Text -> Id
appendToId (Id x) y = Id (x <> y)

type Value = AST
type SearchClause = AST
type Decl = AST

data AST
  = Lit Number
  | Var Id
  | Atom Id [Value]
  | Rule Id [Value] [SearchClause]
  | Module [Decl]
  deriving (Eq, Show)

makePrisms ''AST


scc :: AST -> [[AST]]
scc = \case
  Module decls -> map G.flattenSCC sortedDecls where
    -- TODO: fix issue when loose atom does not appear
    sortedDecls = G.stronglyConnComp $ zipWith (\i d -> (d, i, refersTo d)) [0..] decls
    declLineMapping = M.fromListWith (++) $ zipWith (\i d -> (nameFor d, [i])) [0..] decls
    refersTo = \case
      Rule _ _ clauses -> concatMap (unsafeFromJust . flip M.lookup declLineMapping . nameFor) clauses
      _ -> []
    -- TODO use traversals?
    nameFor = \case
      Atom name _ -> name
      Rule name _ _ -> name
      _ -> Id ""  -- TODO how to handle?
  _ -> panic "Unreachable code in 'scc'"

