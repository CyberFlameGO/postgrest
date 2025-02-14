{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}

module PostgREST.DbStructure.Relationship
  ( Cardinality(..)
  , Relationship(..)
  , Junction(..)
  , RelationshipsMap
  ) where

import qualified Data.Aeson          as JSON
import qualified Data.HashMap.Strict as HM

import PostgREST.DbStructure.Identifiers (FieldName,
                                          QualifiedIdentifier, Schema)

import Protolude


-- | Relationship between two tables.
data Relationship = Relationship
  { relTable        :: QualifiedIdentifier
  , relForeignTable :: QualifiedIdentifier
  , relIsSelf       :: Bool -- ^ Whether is a self relationship
  , relCardinality  :: Cardinality
  , relTableIsView  :: Bool
  , relFTableIsView :: Bool
  }
  | ComputedRelationship
  { relFunction     :: QualifiedIdentifier
  , relTable        :: QualifiedIdentifier
  , relForeignTable :: QualifiedIdentifier
  , relToOne        :: Bool
  , relIsSelf       :: Bool
  }
  deriving (Eq, Ord, Generic, JSON.ToJSON)

-- | The relationship cardinality
-- | https://en.wikipedia.org/wiki/Cardinality_(data_modeling)
data Cardinality
  = O2M {relCons :: FKConstraint, relColumns :: [(FieldName, FieldName)]}
  -- ^ one-to-many
  | M2O {relCons :: FKConstraint, relColumns :: [(FieldName, FieldName)]}
  -- ^ many-to-one
  | O2O {relCons :: FKConstraint, relColumns :: [(FieldName, FieldName)]}
  -- ^ one-to-one, this is a refinement over M2O so operating on it is pretty much the same as M2O
  | M2M Junction
  -- ^ many-to-many
  deriving (Eq, Ord, Generic, JSON.ToJSON)

type FKConstraint = Text

-- | Junction table on an M2M relationship
data Junction = Junction
  { junTable       :: QualifiedIdentifier
  , junConstraint1 :: FKConstraint
  , junConstraint2 :: FKConstraint
  , junColumns1    :: [(FieldName, FieldName)]
  , junColumns2    :: [(FieldName, FieldName)]
  }
  deriving (Eq, Ord, Generic, JSON.ToJSON)

-- | Key based on the source table and the foreign table schema
type RelationshipsMap = HM.HashMap (QualifiedIdentifier, Schema)  [Relationship]
