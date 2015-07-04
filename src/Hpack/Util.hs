{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
module Hpack.Util (
  List(..)
, toModule
, getFilesRecursive
, tryReadFile
, sniffAlignment
, extractFieldOrderHint
, fromMaybeList
, expandGlobs
-- exported for testing
, splitField
) where

import           Control.Applicative
import           Control.Monad
import           Control.Exception
import           Control.DeepSeq
import           Data.Char
import           Data.Either (partitionEithers)
import           Data.Maybe
import           Data.List
import           System.Directory
import           System.FilePath
import           System.FilePath.Glob (namesMatching)
import           Data.Data

import           Data.Aeson.Types

newtype List a = List {fromList :: [a]}
  deriving (Eq, Show, Data, Typeable)

instance FromJSON a => FromJSON (List a) where
  parseJSON v = List <$> (parseJSON v <|> (return <$> parseJSON v))

toModule :: [FilePath] -> Maybe String
toModule path = case reverse path of
  [] -> Nothing
  x : xs -> do
    m <- stripSuffix ".hs" x <|> stripSuffix ".lhs" x
    let name = reverse (m : xs)
    guard (all isValidModuleName name) >> return (intercalate "." name)
  where
    stripSuffix :: String -> String -> Maybe String
    stripSuffix suffix x = reverse <$> stripPrefix (reverse suffix) (reverse x)

-- See `Cabal.Distribution.ModuleName` (http://git.io/bj34)
isValidModuleName :: String -> Bool
isValidModuleName [] = False
isValidModuleName (c:cs) = isUpper c && all isValidModuleChar cs

isValidModuleChar :: Char -> Bool
isValidModuleChar c = isAlphaNum c || c == '_' || c == '\''

getFilesRecursive :: FilePath -> IO [[FilePath]]
getFilesRecursive baseDir = sort <$> go []
  where
    go :: [FilePath] -> IO [[FilePath]]
    go dir = do
      c <- map ((dir ++) . return) . filter (`notElem` [".", ".."]) <$> getDirectoryContents (pathTo dir)
      subdirsFiles  <- filterM (doesDirectoryExist . pathTo) c >>= mapM go
      files <- filterM (doesFileExist . pathTo) c
      return (files ++ concat subdirsFiles)
      where
        pathTo :: [FilePath] -> FilePath
        pathTo p = baseDir </> joinPath p

tryReadFile :: FilePath -> IO (Maybe String)
tryReadFile file = do
  r <- try (readFile file) :: IO (Either IOException String)
  return $!! either (const Nothing) Just r

extractFieldOrderHint :: String -> [String]
extractFieldOrderHint = map fst . catMaybes . map splitField . lines

sniffAlignment :: String -> Maybe Int
sniffAlignment input = case nub . catMaybes . map indentation . catMaybes . map splitField $ lines input of
  [n] -> Just n
  _ -> Nothing
  where

    indentation :: (String, String) -> Maybe Int
    indentation (name, value) = case span isSpace value of
      (_, "") -> Nothing
      (xs, _) -> (Just . succ . length $ name ++ xs)

splitField :: String -> Maybe (String, String)
splitField field = case span isNameChar field of
  (xs, ':':ys) -> Just (xs, ys)
  _ -> Nothing
  where
    isNameChar = (`elem` nameChars)
    nameChars = ['a'..'z'] ++ ['A'..'Z'] ++ "-"


fromMaybeList :: Maybe (List a) -> [a]
fromMaybeList = maybe [] fromList

-- | Expand glob files relative to the given path.
--
-- The globs only support a simple @*@. Notably, the @**@ style for
-- nested-directories is not supported.
expandGlobs :: FilePath -- ^ File path of the config file we are
                        -- reading. The globs are expanded relative to
                        -- the directory the config file is in.
            -> [String] -- ^ A list of globs to expand
            -> IO ([String], [FilePath])
            -- ^ A tuple of warnings and expanded globs
expandGlobs config globs = do
  configDir <- takeDirectory <$> canonicalizePath config
  let -- If the file doesn't match anything, leave it as-is and warn later
      matchOrPreserve f = namesMatching (configDir </> f) >>= return . \case
        [] -> Left f
        xs -> Right xs

  (missing, expanded) <- partitionEithers <$> mapM matchOrPreserve globs
  let allFiles = map (makeRelative configDir) $ concat expanded
  return . (,) (formatMissingExtras missing) . nub $ sort allFiles
  where
    formatMissingExtras = map f
      where
        f name = "Specified extra-source-file " ++ show name
                 ++ " does not exist, skipping"
