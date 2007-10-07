-----------------------------------------------------------------------------
-- |
-- Module      :  Hackage.Dependency
-- Copyright   :  (c) David Himmelstrup 2005, Bjorn Bringert 2007
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Various kinds of dependency resolution and utilities.
-----------------------------------------------------------------------------
module Hackage.Dependency
    (
      resolveDependencies
    , packagesToInstall
    ) where

import Hackage.Config (listInstalledPackages, getKnownPackages)
import Hackage.Types 
    (ResolvedPackage(..), UnresolvedDependency(..), ConfigFlags (..), PkgInfo (..), pkgInfoId)

import Distribution.Version (Dependency(..), withinRange)
import Distribution.Package (PackageIdentifier(..))
import Distribution.PackageDescription 
    (PackageDescription(buildDepends)
    , finalizePackageDescription)
import Distribution.Simple.Compiler (Compiler, showCompilerId, compilerVersion)
import Distribution.Simple.Program (ProgramConfiguration)

import Control.Monad (mplus)
import Data.Char (toLower)
import Data.List (nubBy, maximumBy, isPrefixOf)
import Data.Maybe (fromMaybe)
import qualified System.Info (arch,os)


resolveDependencies :: ConfigFlags
                    -> Compiler
                    -> ProgramConfiguration
                    -> [UnresolvedDependency]
                    -> IO [ResolvedPackage]
resolveDependencies cfg comp conf deps 
    = do installed <- listInstalledPackages cfg comp conf
         available <- getKnownPackages cfg
         return [resolveDependency comp installed available dep opts 
                     | UnresolvedDependency dep opts <- deps]

resolveDependency :: Compiler
                  -> [PackageIdentifier] -- ^ Installed packages.
                  -> [PkgInfo] -- ^ Installable packages
                  -> Dependency
                  -> [String] -- ^ Options for this dependency
                  -> ResolvedPackage
resolveDependency comp installed available dep opts
    = fromMaybe (Unavailable dep) $ resolveFromInstalled `mplus` resolveFromAvailable
  where
    resolveFromInstalled = fmap (Installed dep) $ latestInstalledSatisfying installed dep
    resolveFromAvailable = 
        do pkg <- latestAvailableSatisfying available dep
           let deps = getDependencies comp installed available pkg opts
               resolved = map (\d -> resolveDependency comp installed available d []) deps
           return $ Available dep pkg opts resolved

-- | Gets the latest installed package satisfying a dependency.
latestInstalledSatisfying :: [PackageIdentifier] 
                          -> Dependency -> Maybe PackageIdentifier
latestInstalledSatisfying = latestSatisfying id

-- | Gets the latest available package satisfying a dependency.
latestAvailableSatisfying :: [PkgInfo] 
                          -> Dependency -> Maybe PkgInfo
latestAvailableSatisfying = latestSatisfying pkgInfoId

latestSatisfying :: (a -> PackageIdentifier) 
                 -> [a]
                 -> Dependency
                 -> Maybe a
latestSatisfying f xs dep =
    case filter ((`satisfies` dep) . f) xs of
      [] -> Nothing
      ys -> Just $ maximumBy (comparing (pkgVersion . f)) ys
  where comparing g a b = g a `compare` g b

-- | Checks if a package satisfies a dependency.
satisfies :: PackageIdentifier -> Dependency -> Bool
satisfies pkg (Dependency depName vrange)
    = pkgName pkg == depName && pkgVersion pkg `withinRange` vrange

-- | Gets the dependencies of an available package.
getDependencies :: Compiler 
                -> [PackageIdentifier] -- ^ Installed packages.
                -> [PkgInfo] -- ^ Available packages
                -> PkgInfo
                -> [String] -- ^ Options
                -> [Dependency]
getDependencies comp _installed _available pkg opts
    = case e of
        Left missing   -> error $ "finalizePackage complained about missing dependencies " ++ show missing
        Right (desc,_) -> buildDepends desc
    where 
      flags = configurationsFlags opts
      e = finalizePackageDescription 
                flags
                Nothing --(Just $ nub $ installed ++ map pkgInfoId available) 
                System.Info.os
                System.Info.arch
                (showCompilerId comp, compilerVersion comp)
                (pkgDesc pkg)

-- | Extracts configurations flags from a list of options.
configurationsFlags :: [String] -> [(String, Bool)]
configurationsFlags opts = 
    case filter ("--flags=" `isPrefixOf`) opts of
      [] -> []
      xs -> flagList $ removeQuotes $ drop 8 $ last xs
  where removeQuotes ('"':s) = take (length s - 1) s
        removeQuotes s = s
        flagList = map tagWithValue . words
            where tagWithValue ('-':name) = (map toLower name, False)
                  tagWithValue name       = (map toLower name, True)

packagesToInstall :: [ResolvedPackage] 
                  -> Either [Dependency] [(PkgInfo, [String])]
                     -- ^ Either a list of missing dependencies, or a list
                     -- of packages to install, with their options.
packagesToInstall xs | null missing = Right toInstall
                     | otherwise = Left missing
  where 
    flattened = concatMap flatten xs
    missing = [d | Left d <- flattened]
    toInstall = nubBy samePackage [x | Right x <- flattened]
    samePackage a b = pkgInfoId (fst a) == pkgInfoId (fst b)
    flatten (Installed _ _) = []
    flatten (Available _ p opts deps) = concatMap flatten deps ++ [Right (p,opts)]
    flatten (Unavailable dep) = [Left dep]

