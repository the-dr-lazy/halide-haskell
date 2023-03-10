{-# LANGUAGE OverloadedRecordDot #-}

module Language.Halide.BufferSpec (spec) where

import Data.Int (Int64)
import Foreign.Ptr (Ptr, nullPtr)
import Language.Halide
import Test.Hspec
import Test.Hspec.QuickCheck
import Test.QuickCheck

newtype ListVector a = ListVector [a]
  deriving stock (Show)

newtype ListMatrix a = ListMatrix [[a]]
  deriving stock (Show)

newtype ListTensor3D a = ListTensor3D [[[a]]]
  deriving stock (Show)

instance Arbitrary a => Arbitrary (ListVector a) where
  arbitrary = ListVector <$> listOf arbitrary

instance Arbitrary a => Arbitrary (ListMatrix a) where
  arbitrary = do
    d0 <- chooseInt (0, 50)
    d1 <- chooseInt (0, 50)
    ListMatrix <$> vectorOf d0 (vector d1)

instance Arbitrary a => Arbitrary (ListTensor3D a) where
  arbitrary = do
    d0 <- chooseInt (0, 30)
    d1 <- chooseInt (0, 30)
    d2 <- chooseInt (0, 30)
    ListTensor3D <$> vectorOf d0 (vectorOf d1 (vector d2))

spec :: Spec
spec = do
  it "rowMajorStrides" $ do
    rowMajorStrides [1, 1, 1] `shouldBe` ([1, 1, 1] :: [Int])
    rowMajorStrides [2, 1, 3] `shouldBe` ([3, 3, 1] :: [Int])
    rowMajorStrides [3, 2] `shouldBe` ([2, 1] :: [Int])
    rowMajorStrides [] `shouldBe` ([] :: [Int])
  it "bufferFromPtrShapeStrides" $ do
    bufferFromPtrShapeStrides nullPtr [3, 2, 1] [1, 1, 1] (\(_ :: Ptr (HalideBuffer 2 Int32)) -> pure ())
      `shouldThrow` anyErrorCall
    bufferFromPtrShapeStrides nullPtr [3] [1] (\(_ :: Ptr (HalideBuffer 2 Int32)) -> pure ())
      `shouldThrow` anyErrorCall
  prop "works with [a]" $ \(ListVector xs :: ListVector Float) ->
    withHalideBuffer @1 @Float xs peekToList `shouldReturn` xs
  prop "works with [[a]]" $ \(ListMatrix xs :: ListMatrix Int64) ->
    withHalideBuffer @2 @Int64 xs peekToList `shouldReturn` xs
  prop "works with [[[a]]]" $ \(ListTensor3D xs :: ListTensor3D Double) ->
    withHalideBuffer @3 @Double xs peekToList `shouldReturn` xs