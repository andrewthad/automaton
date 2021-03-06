{-# language BangPatterns #-}
{-# language DeriveFoldable #-}

module Automata.Internal.Transducer
  ( Nfst(..)
  , TransitionNfst(..)
  , Dfst(..)
  , MotionCompactDfst(..)
  , MotionDfst(..)
  , Edge(..)
  , EdgeDest(..)
  , CompactDfst(..)
  , CompactSequence(..)
  , TransitionCompactDfst(..)
  , epsilonClosure
  , rejection
  , union
  ) where

import Control.Monad.ST (runST)
import Data.Primitive (Array)
import Data.Primitive (indexArray)
import qualified Data.Primitive as PM
import qualified Data.Primitive.Contiguous as C
import qualified Data.Set.Unboxed as SU
import qualified Data.Map.Interval.DBTSLL as DM
import qualified Data.Map.Lifted.Unlifted as MLN

-- | An artifact built from a DFST that performs a form of
-- run-length compression to transitions. Consider the DFST
-- over input alphabet @{a,b,c,d}@ with output alphabet
-- @{A,B,C,D}@. The start state is 00:
--
-- > 00 --a/A-> 01 --b/C-> 02 --c/C-> 03 --b/C-+
-- >   \                                        \
-- >    +-b/B-> 04 --c/D-> 05 --d/D-> 06 --b/B-> 07
-- 
-- All unspecified transitions go to state 08 (not shown in
-- the ascii art) with output A. The 'CompactDsft' type
-- would compress states 01-02-03 and states 04-05:
--
-- > 00 --a/A-> 01 --bcb/C-----------+
-- >   \                              \
-- >    +-b/B-> 04 --cd/D-> 06 --b/B-> 07
--
-- All unspecified transitions still go to state 08. Additionally,
-- states with an outgoing RLE transition sequence can transition
-- to 08 if the input string they expect is not fully matched.
-- These RLE transition sequences produce their output token
-- once for every token that is consumed.
data CompactDfst t m = CompactDfst
  { compactDfstTransition :: !(Array (TransitionCompactDfst t))
  , compactDfstFinal :: !(SU.Set Int)
  , compactDfstOutput :: !(Array m)
  }

data TransitionCompactDfst t
  = TransitionCompactDfstSingle (CompactSequence t)
  | TransitionCompactDfstMultiple {-# UNPACK #-} !(DM.Map t MotionCompactDfst)

data CompactSequence t = CompactSequence
  !(Array t) -- sequence of inputs to match, length >= 1
  !Int -- destination after straight-and-narrow path
  !Int -- destination after veering off path
  !Int -- output (as an index) from starting straight-and-narrow path
  !Int -- output (as an index) after veering off path

data MotionCompactDfst = MotionCompactDfst
  { motionCompactDfstState :: !Int -- index into state array
  , motionCompactDfstOutput :: !Int -- index into output array
  } deriving (Eq,Show)


-- | A deterministic finite state transducer.
data Dfst t m = Dfst
  { dfstTransition :: !(Array (DM.Map t (MotionDfst m)))
    -- ^ Given a state and transition, this field tells you what
    --   state to go to next. The length of this array must match
    --   the total number of states.
  , dfstFinal :: !(SU.Set Int)
    -- ^ A string that ends in any of these set of states is
    --   considered to have been accepted by the grammar.
  } deriving (Eq,Show)

data MotionDfst m = MotionDfst
  { motionDfstState :: !Int
  , motionDfstOutput :: !m
  } deriving (Eq,Show)

-- | A nondeterministic finite state transducer. The @t@ represents the input token on
-- which a transition occurs. The @m@ represents the output token that
-- is generated when a transition is taken. On an epsilon transation,
-- no output is generated.
data Nfst t m = Nfst
  { nfstTransition :: !(Array (TransitionNfst t m))
    -- ^ Given a state and transition, this field tells you what
    --   state to go to next. The length of this array must match
    --   the total number of states. The data structure inside is
    --   an interval map. This is capable of collapsing adjacent key-value
    --   pairs into ranges.
  , nfstFinal :: !(SU.Set Int)
    -- ^ A string that ends in any of these set of states is
    --   considered to have been accepted by the grammar.
  } deriving (Eq,Show)

data TransitionNfst t m = TransitionNfst
  { transitionNfstEpsilon :: {-# UNPACK #-} !(SU.Set Int)
  , transitionNfstConsume :: {-# UNPACK #-} !(DM.Map t (MLN.Map m (SU.Set Int)))
  } deriving (Eq,Show)

epsilonClosure :: Array (TransitionNfst m t) -> SU.Set Int -> SU.Set Int
epsilonClosure s states = go states SU.empty where
  go new old = if new == old
    then new
    else
      let together = old <> new
       in go (mconcat (map (\ident -> transitionNfstEpsilon (indexArray s ident)) (SU.toList together)) <> together) together

data Edge t m = Edge !Int !Int !t !t !m

data EdgeDest t m = EdgeDest !Int !t !t !m

-- | Transducer that rejects all input, generating the monoid identity as output.
-- This is the identity for 'union'.
rejection :: (Ord t, Bounded t, Monoid m, Ord m) => Nfst t m
rejection = Nfst
  (C.singleton (TransitionNfst (SU.singleton 0) (DM.pure mempty)))
  SU.empty

-- | Accepts input that is accepts by either of the transducers, producing the
--   output of both of them.
union :: (Bounded t, Ord m) => Nfst t m -> Nfst t m -> Nfst t m
union (Nfst t1 f1) (Nfst t2 f2) = Nfst
  ( runST $ do
      m <- C.replicateMutable (n1 + n2 + 1)
        ( TransitionNfst
          (mconcat
            [ SU.mapMonotonic (+1) (transitionNfstEpsilon (C.index t1 0))
            , SU.mapMonotonic (\x -> 1 + n1 + x) (transitionNfstEpsilon (C.index t2 0))
            , SU.tripleton 0 1 (1 + n1)
            ]
          )
          (DM.pure mempty)
        )
      C.copy m 1 (fmap (translateTransitionNfst 1) t1) 0 n1
      C.copy m (1 + n1) (fmap (translateTransitionNfst (1 + n1)) t2) 0 n2
      C.unsafeFreeze m
  )
  (SU.mapMonotonic (+1) f1 <> SU.mapMonotonic (\x -> 1 + n1 + x) f2)
  where
  !n1 = PM.sizeofArray t1
  !n2 = PM.sizeofArray t2

translateTransitionNfst :: Int -> TransitionNfst t m -> TransitionNfst t m
translateTransitionNfst n (TransitionNfst eps m) = TransitionNfst
  (SU.mapMonotonic (+n) eps)
  (DM.mapBijection (MLN.map (SU.mapMonotonic (+n))) m)

