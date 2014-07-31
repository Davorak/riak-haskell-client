{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving #-}

-- |
-- Module:      Network.Riak.JSON
-- Copyright:   (c) 2011 MailRank, Inc.
-- License:     Apache
-- Maintainer:  Mark Hibberd <mark@hibberd.id.au>, Nathan Hunter <nhunter@janrain.com>
-- Stability:   experimental
-- Portability: portable
--
-- This module allows storage and retrieval of JSON-encoded data.
--
-- The functions in this module do not perform any conflict resolution.

module Network.Riak.JSON
    (
      JSON
    , json
    , plain
    , get
    , getMany
    , put
    , putIndex
    , put_
    , putIndex_
    , putMany
    , putManyIndex
    , putMany_
    , putManyIndex_
    , firstM
    ) where

import Control.Applicative ((<$>))
import Control.Arrow (first)
import Data.Aeson.Types (FromJSON(..), ToJSON(..))
import Data.Monoid (Monoid)
import Data.Typeable (Typeable)
import Network.Riak.Types.Internal
import qualified Network.Riak.Value as V

import Network.Riak.Protocol.Pair
import Network.Riak.Protocol.Content
import qualified Data.Sequence as Seq

newtype JSON a = J {
      plain :: a -- ^ Unwrap a 'JSON'-wrapped value.
    } deriving (Eq, Ord, Show, Read, Bounded, Typeable, Monoid)

-- | Wrap up a value so that it will be encoded and decoded as JSON
-- when converted to/from 'Content'.
json :: (FromJSON a, ToJSON a) => a -> JSON a
json = J
{-# INLINE json #-}

instance Functor JSON where
    fmap f (J a) = J (f a)
    {-# INLINE fmap #-}

instance (FromJSON a, ToJSON a) => V.IsContent (JSON a) where
    parseContent c = J `fmap` (V.parseContent c >>= parseJSON)
    {-# INLINE parseContent #-}

    toContent (J a) = V.toContent (toJSON a)
    {-# INLINE toContent #-}

-- | Retrieve a value.  This may return multiple conflicting siblings.
-- Choosing among them is your responsibility.
get :: (FromJSON c, ToJSON c) => Connection -> Bucket -> Key -> R
    -> IO (Maybe ([c], VClock))
get conn bucket key r = fmap convert <$> V.get conn bucket key r

getMany :: (FromJSON c, ToJSON c) => Connection -> Bucket -> [Key] -> R
    -> IO [Maybe ([c], VClock)]
getMany conn bucket ks r = map (fmap convert) <$> V.getMany conn bucket ks r

-- | Store a single value.  This may return multiple conflicting
-- siblings.  Choosing among them, and storing a new value, is your
-- responsibility.
--
-- You should /only/ supply 'Nothing' as a 'T.VClock' if you are sure
-- that the given bucket+key combination does not already exist.  If
-- you omit a 'T.VClock' but the bucket+key /does/ exist, your value
-- will not be stored.
put
    :: (FromJSON c, ToJSON c) =>
       Connection -> Bucket -> Key -> Maybe VClock -> c
    -> W -> DW -> IO ([c], VClock)
put conn bucket key mvclock val w dw =
    convert <$> V.put conn bucket key mvclock (json val) w dw

firstM mf (x, y) = do
    x' <- mf x
    return (x', y)

putIndex
    :: (FromJSON c, ToJSON c) =>
         Connection -> Bucket -> Key -> Maybe VClock -> c
    -> W -> DW -> Seq.Seq Pair
    -> IO ([c], VClock)
putIndex conn bucket key mvclock val w dw ind =
--    convert <$> (V.put conn bucket key mvclock (json val) w dw)
    convert <$> (firstM (V.convert . Seq.fromList) =<< V.put conn bucket key mvclock jvi w dw)
  where
    jv = V.toContent . json $ val
    jvi = jv { indexes = indexes jv Seq.>< ind }

-- | Store a single value, without the possibility of conflict
-- resolution.
--
-- You should /only/ supply 'Nothing' as a 'T.VClock' if you are sure
-- that the given bucket+key combination does not already exist.  If
-- you omit a 'T.VClock' but the bucket+key /does/ exist, your value
-- will not be stored, and you will not be notified.
put_
    :: (FromJSON c, ToJSON c) =>
       Connection -> Bucket -> Key -> Maybe VClock -> c
    -> W -> DW -> IO ()
put_ conn bucket key mvclock val w dw =
    V.put_ conn bucket key mvclock (json val) w dw

putIndex_
    :: (FromJSON c, ToJSON c) =>
       Connection -> Bucket -> Key -> Maybe VClock -> c
    -> W -> DW -> Seq.Seq Pair
    -> IO ()
putIndex_ conn bucket key mvclock val w dw ind =
    V.put_ conn bucket key mvclock jvi w dw
  where
    jv = V.toContent . json $ val
    jvi = jv { indexes = indexes jv Seq.>< ind }

-- | Store many values.  This may return multiple conflicting siblings
-- for each value stored.  Choosing among them, and storing a new
-- value in each case, is your responsibility.
--
-- You should /only/ supply 'Nothing' as a 'T.VClock' if you are sure
-- that the given bucket+key combination does not already exist.  If
-- you omit a 'T.VClock' but the bucket+key /does/ exist, your value
-- will not be stored.
putMany :: (FromJSON c, ToJSON c) =>
           Connection -> Bucket -> [(Key, Maybe VClock, c)]
        -> W -> DW -> IO [([c], VClock)]
putMany conn bucket puts w dw =
    map convert <$> V.putMany conn bucket (map f puts) w dw
  where
    f (k, v, c) = (k, v, json c)

putManyIndex :: (FromJSON c, ToJSON c) =>
           Connection -> Bucket -> [(Key, Maybe VClock, Seq.Seq Pair, c)]
        -> W -> DW -> IO [([c], VClock)]
putManyIndex conn bucket puts w dw =
--    map convert <$> V.putMany conn bucket (map f puts) w dw
    map convert <$> (mapM (firstM (V.convert . Seq.fromList)) =<< V.putMany conn bucket (map f puts) w dw)
  where
--    f (k, v, i, c) = (k, v, json c)
    f (k, v, i, c) = (k, v, jvi)
      where
        jv = V.toContent . json $ c
        jvi = jv { indexes = indexes jv Seq.>< i }

-- | Store many values, without the possibility of conflict
-- resolution.
--
-- You should /only/ supply 'Nothing' as a 'T.VClock' if you are sure
-- that the given bucket+key combination does not already exist.  If
-- you omit a 'T.VClock' but the bucket+key /does/ exist, your value
-- will not be stored, and you will not be notified.
putMany_ :: (FromJSON c, ToJSON c) =>
            Connection -> Bucket -> [(Key, Maybe VClock, c)]
         -> W -> DW -> IO ()
putMany_ conn bucket puts w dw = V.putMany_ conn bucket (map f puts) w dw
  where
    f (k, v, c) = (k, v, json c)

putManyIndex_ :: (FromJSON c, ToJSON c) =>
            Connection -> Bucket -> [(Key, Maybe VClock, Seq.Seq Pair, c)]
         -> W -> DW -> IO ()
putManyIndex_ conn bucket puts w dw = V.putMany_ conn bucket (map f puts) w dw
  where
    f (k, v, i, c) = (k, v, jvi)
      where
        jv = V.toContent . json $ c
        jvi = jv { indexes = indexes jv Seq.>< i }

convert :: ([JSON a], VClock) -> ([a], VClock)
convert = first (map plain)
