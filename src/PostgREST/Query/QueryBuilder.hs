{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-|
Module      : PostgREST.Query.QueryBuilder
Description : PostgREST SQL queries generating functions.

This module provides functions to consume data types that
represent database queries (e.g. ReadRequest, MutateRequest) and SqlFragment
to produce SqlQuery type outputs.
-}
module PostgREST.Query.QueryBuilder
  ( readRequestToQuery
  , mutateRequestToQuery
  , readRequestToCountQuery
  , requestToCallProcQuery
  , limitedQuery
  ) where

import qualified Data.ByteString.Char8           as BS
import qualified Data.Set                        as S
import qualified Hasql.DynamicStatements.Snippet as SQL

import Data.Tree (Tree (..))

import PostgREST.DbStructure.Identifiers  (QualifiedIdentifier (..))
import PostgREST.DbStructure.Proc         (ProcParam (..))
import PostgREST.DbStructure.Relationship (Cardinality (..),
                                           Junction (..),
                                           Relationship (..))
import PostgREST.Request.Preferences      (PreferResolution (..))

import PostgREST.Query.SqlFragment
import PostgREST.RangeQuery          (allRange)
import PostgREST.Request.MutateQuery
import PostgREST.Request.ReadQuery
import PostgREST.Request.Types

import Protolude

readRequestToQuery :: ReadRequest -> SQL.Snippet
readRequestToQuery (Node (Select colSelects mainQi tblAlias logicForest joinConditions_ ordts range, (_, rel, _, _, _, _)) forest) =
  "SELECT " <>
  intercalateSnippet ", " ((pgFmtSelectItem qi <$> colSelects) ++ selects) <> " " <>
  fromFrag <> " " <>
  intercalateSnippet " " joins <> " " <>
  (if null logicForest && null joinConditions_
    then mempty
    else "WHERE " <> intercalateSnippet " AND " (map (pgFmtLogicTree qi) logicForest ++ map pgFmtJoinCondition joinConditions_)) <> " " <>
  orderF qi ordts <> " " <>
  limitOffsetF range
  where
    fromFrag = fromF rel mainQi tblAlias
    qi = getQualifiedIdentifier rel mainQi tblAlias
    (selects, joins) = foldr getSelectsJoins ([],[]) forest

getSelectsJoins :: ReadRequest -> ([SQL.Snippet], [SQL.Snippet]) -> ([SQL.Snippet], [SQL.Snippet])
getSelectsJoins (Node (_, (_, Nothing, _, _, _, _)) _) _ = ([], [])
getSelectsJoins rr@(Node (_, (name, Just rel, alias, _, joinType, _)) _) (selects,joins) =
  let
    subquery = readRequestToQuery rr
    aliasOrName = fromMaybe name alias
    locTblName = qiName (relTable rel) <> "_" <> aliasOrName
    localTableName = pgFmtIdent locTblName
    internalTableName = pgFmtIdent $ "_" <> locTblName
    correlatedSubquery sub al cond =
      (if joinType == Just JTInner then "INNER" else "LEFT") <> " JOIN LATERAL ( " <> sub <> " ) AS " <> SQL.sql al <> " ON " <> cond
    isToOne = case rel of
      Relationship{relCardinality=M2O _ _} -> True
      Relationship{relCardinality=O2O _ _} -> True
      ComputedRelationship{relToOne=True}  -> True
      _                                    -> False
    (sel, joi) = if isToOne
      then
        ( SQL.sql ("row_to_json(" <> localTableName <> ".*) AS " <> pgFmtIdent aliasOrName)
        , correlatedSubquery subquery localTableName "TRUE")
      else
        ( SQL.sql $ "COALESCE( " <> localTableName <> "." <> internalTableName <> ", '[]') AS " <> pgFmtIdent aliasOrName
        , correlatedSubquery (
            "SELECT json_agg(" <> SQL.sql internalTableName <> ") AS " <> SQL.sql internalTableName <>
            "FROM (" <> subquery <> " ) AS " <> SQL.sql internalTableName
          ) localTableName $ if joinType == Just JTInner then SQL.sql localTableName <> " IS NOT NULL" else "TRUE")
  in
  (sel:selects, joi:joins)

mutateRequestToQuery :: MutateRequest -> SQL.Snippet
mutateRequestToQuery (Insert mainQi iCols body onConflct putConditions returnings) =
  "WITH " <> normalizedBody body <> " " <>
  "INSERT INTO " <> SQL.sql (fromQi mainQi) <> SQL.sql (if S.null iCols then " " else "(" <> cols <> ") ") <>
  "SELECT " <> SQL.sql cols <> " " <>
  SQL.sql ("FROM json_populate_recordset (null::" <> fromQi mainQi <> ", " <> selectBody <> ") _ ") <>
  -- Only used for PUT
  (if null putConditions then mempty else "WHERE " <> intercalateSnippet " AND " (pgFmtLogicTree (QualifiedIdentifier mempty "_") <$> putConditions)) <>
  SQL.sql (BS.unwords [
    maybe "" (\(oncDo, oncCols) ->
      if null oncCols then
        mempty
      else
        "ON CONFLICT(" <> BS.intercalate ", " (pgFmtIdent <$> oncCols) <> ") " <> case oncDo of
        IgnoreDuplicates ->
          "DO NOTHING"
        MergeDuplicates  ->
          if S.null iCols
             then "DO NOTHING"
             else "DO UPDATE SET " <> BS.intercalate ", " (pgFmtIdent <> const " = EXCLUDED." <> pgFmtIdent <$> S.toList iCols)
      ) onConflct,
    returningF mainQi returnings
    ])
  where
    cols = BS.intercalate ", " $ pgFmtIdent <$> S.toList iCols

-- An update without a limit is always filtered with a WHERE
mutateRequestToQuery (Update mainQi uCols body logicForest range ordts returnings)
  | S.null uCols =
    -- if there are no columns we cannot do UPDATE table SET {empty}, it'd be invalid syntax
    -- selecting an empty resultset from mainQi gives us the column names to prevent errors when using &select=
    -- the select has to be based on "returnings" to make computed overloaded functions not throw
    SQL.sql $ "SELECT " <> emptyBodyReturnedColumns <> " FROM " <> fromQi mainQi <> " WHERE false"

  | range == allRange =
    "WITH " <> normalizedBody body <> " " <>
    "UPDATE " <> mainTbl <> " SET " <> SQL.sql nonRangeCols <> " " <>
    "FROM (SELECT * FROM json_populate_recordset (null::" <> mainTbl <> " , " <> SQL.sql selectBody <> " )) _ " <>
    whereLogic <> " " <>
    SQL.sql (returningF mainQi returnings)

  | otherwise =
    "WITH " <> normalizedBody body <> ", " <>
    "pgrst_update_body AS (SELECT * FROM json_populate_recordset (null::" <> mainTbl <> " , " <> SQL.sql selectBody <> " ) LIMIT 1), " <>
    "pgrst_affected_rows AS (" <>
      "SELECT " <> SQL.sql rangeIdF <> " FROM " <> mainTbl <>
      whereLogic <> " " <>
      orderF mainQi ordts <> " " <>
      limitOffsetF range <>
    ") " <>
    "UPDATE " <> mainTbl <> " SET " <> SQL.sql rangeCols <>
    "FROM pgrst_affected_rows " <>
    "WHERE " <> SQL.sql whereRangeIdF <> " " <>
    SQL.sql (returningF mainQi returnings)

  where
    whereLogic = if null logicForest then mempty else " WHERE " <> intercalateSnippet " AND " (pgFmtLogicTree mainQi <$> logicForest)
    mainTbl = SQL.sql (fromQi mainQi)
    emptyBodyReturnedColumns = if null returnings then "NULL" else BS.intercalate ", " (pgFmtColumn (QualifiedIdentifier mempty $ qiName mainQi) <$> returnings)
    nonRangeCols = BS.intercalate ", " (pgFmtIdent <> const " = _." <> pgFmtIdent <$> S.toList uCols)
    rangeCols = BS.intercalate ", " ((\col -> pgFmtIdent col <> " = (SELECT " <> pgFmtIdent col <> " FROM pgrst_update_body) ") <$> S.toList uCols)
    (whereRangeIdF, rangeIdF) = mutRangeF mainQi (fst . otTerm <$> ordts)

mutateRequestToQuery (Delete mainQi logicForest range ordts returnings)
  | range == allRange =
    "DELETE FROM " <> SQL.sql (fromQi mainQi) <> " " <>
    whereLogic <> " " <>
    SQL.sql (returningF mainQi returnings)

  | otherwise =
    "WITH " <>
    "pgrst_affected_rows AS (" <>
      "SELECT " <> SQL.sql rangeIdF <> " FROM " <> SQL.sql (fromQi mainQi) <>
       whereLogic <> " " <>
      orderF mainQi ordts <> " " <>
      limitOffsetF range <>
    ") " <>
    "DELETE FROM " <> SQL.sql (fromQi mainQi) <> " " <>
    "USING pgrst_affected_rows " <>
    "WHERE " <> SQL.sql whereRangeIdF <> " " <>
    SQL.sql (returningF mainQi returnings)

  where
    whereLogic = if null logicForest then mempty else " WHERE " <> intercalateSnippet " AND " (pgFmtLogicTree mainQi <$> logicForest)
    (whereRangeIdF, rangeIdF) = mutRangeF mainQi (fst . otTerm <$> ordts)

requestToCallProcQuery :: CallRequest -> SQL.Snippet
requestToCallProcQuery (FunctionCall qi params args returnsScalar multipleCall returnings) =
  prmsCTE <> argsBody
  where
    (prmsCTE, argFrag) = case params of
      OnePosParam prm -> ("WITH pgrst_args AS (SELECT NULL)", singleParameter args (encodeUtf8 $ ppType prm))
      KeyParams []    -> (mempty, mempty)
      KeyParams prms  -> (
          "WITH " <> normalizedBody args <> ", " <>
          SQL.sql (
            BS.unwords [
            "pgrst_args AS (",
              "SELECT * FROM json_to_recordset(" <> selectBody <> ") AS _(" <> fmtParams prms (const mempty) (\a -> " " <> encodeUtf8 (ppType a)) <> ")",
            ")"])
         , SQL.sql $ if multipleCall
             then fmtParams prms varadicPrefix (\a -> " := pgrst_args." <> pgFmtIdent (ppName a))
             else fmtParams prms varadicPrefix (\a -> " := (SELECT " <> pgFmtIdent (ppName a) <> " FROM pgrst_args LIMIT 1)")
        )

    fmtParams :: [ProcParam] -> (ProcParam -> SqlFragment) -> (ProcParam -> SqlFragment) -> SqlFragment
    fmtParams prms prmFragPre prmFragSuf = BS.intercalate ", "
      ((\a -> prmFragPre a <> pgFmtIdent (ppName a) <> prmFragSuf a) <$> prms)

    varadicPrefix :: ProcParam -> SqlFragment
    varadicPrefix a = if ppVar a then "VARIADIC " else mempty

    argsBody :: SQL.Snippet
    argsBody
      | multipleCall =
          if returnsScalar
            then "SELECT " <> callIt <> " AS pgrst_scalar FROM pgrst_args"
            else "SELECT pgrst_lat_args.* FROM pgrst_args, " <>
                 "LATERAL ( SELECT " <> returnedColumns <> " FROM " <> callIt <> " ) pgrst_lat_args"
      | otherwise =
          if returnsScalar
            then "SELECT " <> callIt <> " AS pgrst_scalar"
            else "SELECT " <> returnedColumns <> " FROM " <> callIt

    callIt :: SQL.Snippet
    callIt = SQL.sql (fromQi qi) <> "(" <> argFrag <> ")"

    returnedColumns :: SQL.Snippet
    returnedColumns
      | null returnings = "*"
      | otherwise       = SQL.sql $ BS.intercalate ", " (pgFmtColumn (QualifiedIdentifier mempty $ qiName qi) <$> returnings)


-- | SQL query meant for COUNTing the root node of the Tree.
-- It only takes WHERE into account and doesn't include LIMIT/OFFSET because it would reduce the COUNT.
-- SELECT 1 is done instead of SELECT * to prevent doing expensive operations(like functions based on the columns)
-- inside the FROM target.
-- If the request contains INNER JOINs, then the COUNT of the root node will change.
-- For this case, we use a WHERE EXISTS instead of an INNER JOIN on the count query.
-- See https://github.com/PostgREST/postgrest/issues/2009#issuecomment-977473031
-- Only for the nodes that have an INNER JOIN linked to the root level.
readRequestToCountQuery :: ReadRequest -> SQL.Snippet
readRequestToCountQuery (Node (Select{from=mainQi, fromAlias=tblAlias, where_=logicForest, joinConditions=joinConditions_}, (_, rel, _, _, _, _)) forest) =
  "SELECT 1 " <> fromFrag <>
  (if null logicForest && null joinConditions_ && null subQueries
    then mempty
    else " WHERE " ) <>
  intercalateSnippet " AND " (
    map (pgFmtLogicTree qi) logicForest ++
    map pgFmtJoinCondition joinConditions_ ++
    subQueries
  )
  where
    qi = getQualifiedIdentifier rel mainQi tblAlias
    fromFrag = fromF rel mainQi tblAlias
    subQueries = foldr existsSubquery [] forest
    existsSubquery :: ReadRequest -> [SQL.Snippet] -> [SQL.Snippet]
    existsSubquery readReq@(Node (_, (_, _, _, _, joinType, _)) _) rest =
      if joinType == Just JTInner
        then ("EXISTS (" <> readRequestToCountQuery readReq <> " )"):rest
        else rest

limitedQuery :: SQL.Snippet -> Maybe Integer -> SQL.Snippet
limitedQuery query maxRows = query <> SQL.sql (maybe mempty (\x -> " LIMIT " <> BS.pack (show x)) maxRows)

-- TODO refactor so this function is uneeded and ComputedRelationship QualifiedIdentifier comes from the ReadQuery type
getQualifiedIdentifier :: Maybe Relationship -> QualifiedIdentifier -> Maybe Alias -> QualifiedIdentifier
getQualifiedIdentifier rel mainQi tblAlias = case rel of
  Just ComputedRelationship{relFunction} -> QualifiedIdentifier mempty $ fromMaybe (qiName relFunction) tblAlias
  _                                      -> maybe mainQi (QualifiedIdentifier mempty) tblAlias

-- FROM clause plus implicit joins
fromF :: Maybe Relationship -> QualifiedIdentifier -> Maybe Alias -> SQL.Snippet
fromF rel mainQi tblAlias = SQL.sql $ "FROM " <>
  (case rel of
    Just ComputedRelationship{relFunction,relTable} -> fromQi relFunction <> "(" <> pgFmtIdent (qiName relTable) <> ")"
    _                                               -> fromQi mainQi) <>
  maybe mempty (\a -> " AS " <> pgFmtIdent a) tblAlias <>
  (case rel of
    Just Relationship{relCardinality=M2M Junction{junTable=jt}} -> ", " <> fromQi jt
    _                                                           -> mempty)
