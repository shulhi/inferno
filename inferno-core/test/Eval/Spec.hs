{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

module Eval.Spec where

import Control.Monad.Except (ExceptT)
import Control.Monad.IO.Class (liftIO)
import Data.Bifunctor (bimap)
import Data.Int (Int64)
import qualified Data.List.NonEmpty as NEList
import qualified Data.Map as Map
import Data.Text (unpack)
import Inferno.Eval.Error (EvalError (..))
import Inferno.Infer (inferExpr)
import Inferno.Infer.Pinned (pinExpr)
import Inferno.Module.Builtin (enumBoolHash)
import Inferno.Parse (parseExpr, prettyError)
import Inferno.Types.Syntax (Expr (App, TypeRep), ExtIdent (..), Ident (..))
import Inferno.Types.Type (typeDouble, typeInt)
import Inferno.Types.Value (Value (..))
import Inferno.Types.VersionControl (pinnedToMaybe)
import Inferno.Utils.Prettyprinter (renderPretty)
import Test.Hspec (Spec, describe, expectationFailure, it, shouldBe)
import Text.Megaparsec (initialPos)
import Utils (TestCustomValue, baseOpsTable, builtinModules, builtinModulesOpsTable, builtinModulesPinMap, builtinModulesTerms, runEvalIO)

evalTests :: Spec
evalTests = describe "evaluate" $
  do
    shouldEvaluateToWithTRep typeInt "3" $ VInt 3
    shouldEvaluateToWithTRep typeInt "-3" $ VInt (-3)
    shouldEvaluateToWithTRep typeDouble "3" $ VDouble 3
    shouldEvaluateToWithTRep typeDouble "-3" $ VDouble (-3)
    shouldEvaluateToWithTRep typeInt "-(-3)" $ VInt 3
    shouldEvaluateToWithTReps [typeInt, typeInt] "3+4" $ VInt 7
    shouldEvaluateTo "3.0" $ VDouble 3.0
    shouldEvaluateTo "3.0-2" $ VDouble 1.0
    shouldEvaluateTo "3.0/2" $ VDouble 1.5
    -- Reciprocals
    shouldEvaluateTo "3.14 * recip 3.14" $ VDouble 1.0
    -- Power
    shouldEvaluateToWithTRep typeInt "14 ** 5" $ VInt (14 ^ (5 :: Int64))
    shouldEvaluateTo "1.4 ** 2.5" $ VDouble (1.4 ** 2.5)
    shouldEvaluateTo "exp 0" $ VDouble 1.0
    shouldEvaluateTo "exp (ln 1)" $ VDouble 1.0
    -- Logs
    shouldEvaluateTo "log 10" $ VDouble 1.0
    shouldEvaluateTo "logBase 10 100" $ VDouble 2.0
    shouldEvaluateTo "ln (exp 1)" $ VDouble 1.0
    -- Square root
    shouldEvaluateTo "sqrt 1.425" $ VDouble (sqrt 1.425)
    shouldEvaluateTo "sqrt (-1.425)" $ VDouble (sqrt (-1.425))
    -- Negation
    shouldEvaluateToWithTRep typeInt "let x = 1425 in -x" $ VInt (-1425)
    shouldEvaluateTo "let x = 1.425 in -x" $ VDouble (-1.425)
    -- Absolute value
    shouldEvaluateToWithTRep typeInt "abs 1425" $ VInt 1425
    shouldEvaluateToWithTRep typeInt "abs (-1425)" $ VInt 1425
    shouldEvaluateToWithTRep typeDouble "abs 1425" $ VDouble 1425
    shouldEvaluateToWithTRep typeDouble "abs (-1425)" $ VDouble 1425
    shouldEvaluateTo "abs 14.25" $ VDouble 14.25
    shouldEvaluateTo "abs (-14.25)" $ VDouble 14.25
    -- Modulus
    shouldEvaluateTo "1425 % 5" $ VInt 0
    shouldEvaluateTo "1426 % 5" $ VInt 1
    shouldEvaluateTo "-3 % 5" $ VInt 2
    -- Floor and ceiling
    shouldEvaluateTo "floor 1425" $ VInt 1425
    shouldEvaluateTo "floor (-1425)" $ VInt (-1425)
    shouldEvaluateTo "floor 14.25" $ VInt 14
    shouldEvaluateTo "floor (-14.25)" $ VInt (-15)
    shouldEvaluateTo "ceiling 1425" $ VInt 1425
    shouldEvaluateTo "ceiling (-1425)" $ VInt (-1425)
    shouldEvaluateTo "ceiling 14.25" $ VInt 15
    shouldEvaluateTo "ceiling (-14.25)" $ VInt (-14)
    -- Rounding
    shouldEvaluateTo "round 1425" $ VInt 1425
    shouldEvaluateTo "round (-1425)" $ VInt (-1425)
    shouldEvaluateTo "round 14.25" $ VInt 14
    shouldEvaluateTo "round 14.55" $ VInt 15
    shouldEvaluateTo "round (-14.25)" $ VInt (-14)
    shouldEvaluateTo "round (-14.55)" $ VInt (-15)
    -- TODO fix type inference here? Check types inferred
    shouldEvaluateTo "roundTo 0 1.72839" $ VDouble 2.0
    shouldEvaluateTo "roundTo 1 1.72839" $ VDouble 1.7
    shouldEvaluateTo "roundTo 2 1.72839" $ VDouble 1.73
    shouldEvaluateTo "roundTo 3 1.72839" $ VDouble 1.728
    shouldEvaluateTo "roundTo 4 1.72839" $ VDouble 1.7284
    shouldEvaluateTo "roundTo 5 1.72839" $ VDouble 1.72839
    shouldEvaluateTo "truncate 1425" $ VInt 1425
    shouldEvaluateTo "truncate (-1425)" $ VInt (-1425)
    shouldEvaluateTo "truncate 14.25" $ VInt 14
    shouldEvaluateTo "truncate 14.55" $ VInt 14
    shouldEvaluateTo "truncate (-14.25)" $ VInt (-14)
    shouldEvaluateTo "truncate (-14.55)" $ VInt (-14)
    shouldEvaluateTo "truncateTo 0 1.72839" $ VDouble 1.0
    shouldEvaluateTo "truncateTo 1 1.72839" $ VDouble 1.7
    shouldEvaluateTo "truncateTo 2 1.72839" $ VDouble 1.72
    shouldEvaluateTo "truncateTo 3 1.72839" $ VDouble 1.728
    shouldEvaluateTo "truncateTo 4 1.72839" $ VDouble 1.7283
    -- Limit
    shouldEvaluateTo "limit 1.72 9.32 (-23.4)" $ VDouble 1.72
    shouldEvaluateTo "limit 1.72 9.32 3.4" $ VDouble 3.4
    shouldEvaluateTo "limit 1.72 9.32 9.32" $ VDouble 9.32
    shouldEvaluateTo "limit 1.72 9.32 233.4" $ VDouble 9.32
    -- Trigonometry
    shouldEvaluateTo "(sin 1.87) ** 2.0 + (cos 1.87) ** 2.0" $ VDouble 1.0
    shouldEvaluateTo "(cosh 1.87) ** 2.0 - (sinh 1.87) ** 2.0" $ VDouble 1.0
    shouldEvaluateTo "tanh 1.87" $ VDouble (sinh 1.87 / cosh 1.87)
    shouldEvaluateTo "truncateTo 4 ((sin 1.87 / (cos 1.87)) - tan 1.87)" $ VDouble 0.0
    shouldEvaluateTo "truncateTo 4 (sin (2 * pi))" $ VDouble 0.0
    shouldEvaluateTo "arcSin (sin 1.02)" $ VDouble 1.02
    shouldEvaluateTo "arcCos (cos 1.02)" $ VDouble 1.02
    shouldEvaluateTo "arcTan (tan 1.02)" $ VDouble 1.02
    -- Booleans
    shouldEvaluateTo "#true" vTrue
    shouldEvaluateTo "!#true" vFalse
    shouldEvaluateTo "!(!#true)" vTrue
    shouldEvaluateTo "#false && #false" vFalse
    shouldEvaluateTo "#true && #false" vFalse
    shouldEvaluateTo "#true && #true" vTrue
    shouldEvaluateTo "#false || #false" vFalse
    shouldEvaluateTo "#true || #false" vTrue
    shouldEvaluateTo "#true || #true" vTrue
    shouldEvaluateTo "#false XOR #false" vFalse
    shouldEvaluateTo "#true XOR #false" vTrue
    shouldEvaluateTo "#true XOR #true" vFalse
    shouldEvaluateTo "#true XOR #true || #true" vTrue
    shouldEvaluateTo "#true || #true XOR #true" vTrue
    shouldEvaluateTo "(#true XOR #true) || #true" vTrue
    shouldEvaluateTo "#true XOR (#true || #true)" vFalse
    shouldEvaluateTo "#true && #false || #true" vTrue
    shouldEvaluateTo "#true || #false && #true" vTrue
    -- Order
    shouldEvaluateTo "1.2 < 8.9" vTrue
    shouldEvaluateTo "-1.2 < -8.9" vFalse
    shouldEvaluateTo "-1.2 < -1.2" vFalse
    shouldEvaluateTo "1.2 > 8.9" vFalse
    shouldEvaluateTo "-1.2 > -8.9" vTrue
    shouldEvaluateTo "-1.2 > -1.2" vFalse
    shouldEvaluateTo "1.2 <= 8.9" vTrue
    shouldEvaluateTo "-1.2 <= (-8.9)" vFalse
    shouldEvaluateTo "-1.2 <= -1.2" vTrue
    shouldEvaluateTo "1.2 >= 8.9" vFalse
    shouldEvaluateTo "-1.2 >= -8.9" vTrue
    shouldEvaluateTo "-1.2 >= -1.2" vTrue
    shouldEvaluateTo "min 1.23 4.33" $ VDouble 1.23
    shouldEvaluateTo "min 11.23 4.33" $ VDouble 4.33
    shouldEvaluateTo "max 1.23 4.33" $ VDouble 4.33
    shouldEvaluateTo "max 11.23 4.33" $ VDouble 11.23
    -- equality is defined for all types, however comparing function types will always yield #false
    shouldEvaluateTo "1.2 == 1.2" vTrue
    shouldEvaluateTo "-1.2 == -1.2" vTrue
    shouldEvaluateTo "1.2 == 3.2" vFalse
    shouldEvaluateTo "1.2 != 1.2" vFalse
    shouldEvaluateTo "-1.2 != -1.2" vFalse
    shouldEvaluateTo "1.2 != 3.2" vTrue
    shouldEvaluateTo "12 == 12" vTrue
    shouldEvaluateTo "-12 == -12" vTrue
    shouldEvaluateTo "12 == 32" vFalse
    shouldEvaluateTo "12 != 12" vFalse
    shouldEvaluateTo "-12 != -12" vFalse
    shouldEvaluateTo "12 != 32" vTrue
    shouldEvaluateTo "(fun x -> x) == (fun x -> x)" vFalse
    shouldEvaluateTo "(fun x -> x) != (fun x -> x)" vTrue
    -- Bits
    shouldEvaluateTo "0x3abc" $ VWord64 15036
    shouldEvaluateTo "testBit 0x1 0" vTrue
    shouldEvaluateTo "testBit 0x1 1" vFalse
    shouldEvaluateTo "testBit 0x2 0" vFalse
    shouldEvaluateTo "testBit (setBit 0x0 3) 3" vTrue
    shouldEvaluateTo "testBit (setBit 0x0 3) 2" vFalse
    shouldEvaluateTo "testBit (clearBit (setBit 0x0 3) 2) 3" vTrue
    shouldEvaluateTo "testBit (clearBit (setBit 0x0 3) 3) 3" vFalse
    shouldEvaluateTo "testBit (complementBit 0x0 3) 3" vTrue
    shouldEvaluateTo "testBit (complementBit (complementBit 0x0 3) 3) 3" vFalse
    shouldEvaluateTo "shift 0x1 3" $ VWord64 8
    shouldEvaluateTo "shift 0x10 (-3)" $ VWord64 2
    shouldEvaluateTo "0x10 && 0x01" $ VWord64 0
    shouldEvaluateTo "0x5 && 0x9" $ VWord64 1
    shouldEvaluateTo "0x5 && 0x6" $ VWord64 4
    shouldEvaluateTo "0x5 || 0x9" $ VWord64 13
    shouldEvaluateTo "0x5 || 0x6" $ VWord64 7
    shouldEvaluateTo "0x5 XOR 0x9" $ VWord64 12
    shouldEvaluateTo "0x5 XOR 0x6" $ VWord64 3
    shouldEvaluateTo "0x10 XOR 0x01" $ VWord64 17
    shouldEvaluateTo "!(toWord16 0x1)" $ VWord64 (fromIntegral (2 ^ (16 :: Integer) - (2 :: Integer)))
    shouldEvaluateTo "toWord16 #true" $ VWord16 1
    shouldEvaluateTo "toWord16 (toWord64 77)" $ VWord16 77
    shouldEvaluateTo "toWord16 (toWord64 (2**17 + 2))" $ VWord16 2
    shouldEvaluateTo "toWord32 (toWord64 77)" $ VWord32 77
    shouldEvaluateTo "toWord32 (toWord64 (2**33 + 5))" $ VWord32 5
    shouldEvaluateTo "toWord64 (toWord16 (2**62 + 1))" $ VWord64 1
    shouldEvaluateTo "fromWord (toWord64 (2**62))" $ VInt (2 ^ (62 :: Int64))
    shouldEvaluateTo "fromWord (toWord32 (2**62 + 2**31))" $ VInt (2 ^ (31 :: Int64))
    shouldEvaluateTo "fromWord (toWord16 (2**31 + 2**3))" $ VInt 8
    shouldEvaluateTo "fromWord #false" $ VInt 0
    shouldEvaluateTo "fromWord #true" $ VInt 1
    -- Arrays
    shouldEvaluateTo "Array.singleton 3.14" $ VArray [VDouble 3.14]
    shouldEvaluateTo "Array.length []" $ VInt 0
    shouldEvaluateTo "Array.length [3.0, 4.0]" $ VInt 2
    shouldEvaluateTo "Array.minimum [3.0, 4.0]" $ VDouble 3.0
    shouldEvaluateTo "Array.maximum [3.0, 4.0]" $ VDouble 4.0
    shouldEvaluateTo "Array.average [0.0, 1.0]" $ VDouble 0.5
    shouldEvaluateTo "Array.argmin [3.0, 4.0]" $ VInt 0
    shouldEvaluateTo "Array.argmax [3.0, 4.0]" $ VInt 1
    shouldEvaluateTo "Array.argsort [3.0, 1.0, 2.0]" $ VArray [VInt 1, VInt 2, VInt 0]
    shouldEvaluateTo "Array.magnitude [1.0, 2.0, 3.0]" $ VDouble (sqrt (1.0 + 4.0 + 9.0))
    shouldEvaluateTo "Array.norm [1.0, -2.0, 3.0]" $ VDouble (sqrt (1.0 + 4.0 + 9.0))

    shouldEvaluateTo "Array.range 4 3" $ VArray []
    shouldEvaluateTo "Array.range 4 13" $ VArray (map VInt [4 .. 13])
    shouldEvaluateTo "4 .. 13" $ VArray (map VInt [4 .. 13])
    shouldEvaluateTo "Array.map (fun x -> x**2) (Array.range 1 4)" $ VArray (map VInt [1, 4, 9, 16])
    -- The output type depends on the type of the starting value 0:
    shouldEvaluateToWithTRep typeInt "Array.reduce (fun x y -> x + max 0 y) 0 (Array.range (-3) 3)" $ VInt 6
    shouldEvaluateToWithTRep typeDouble "Array.reduce (fun x y -> x + max 0 y) 0 (Array.range (-3) 3)" $ VDouble 6
    shouldEvaluateToWithTRep typeInt "Array.reduceRight (fun x y -> y + max 0 x) 0 (Array.range (-3) 3)" $ VInt 6
    shouldEvaluateToWithTRep typeDouble "Array.reduceRight (fun x y -> y + max 0 x) 0 (Array.range (-3) 3)" $ VDouble 6
    shouldEvaluateTo "(Array.reduce (fun x y -> x + max 0 y) 0 ((-3) .. 3)) == 6" vTrue
    shouldEvaluateTo "(Array.reduce (fun x y -> x + max 0 y) 0 ((-3) .. 3)) == 6.0" vTrue
    shouldEvaluateTo "(Array.reduce (fun x y -> x + max 0 y) 0 ((-3) .. 3)) == (Array.reduceRight (fun x y -> y + max 0 x) 0 ((-3) .. 3))" vTrue
    -- This needs two type reps: one for the zero in sumArray, and one for the array elements
    shouldEvaluateToWithTReps [typeInt, typeInt] "Array.sum [1, 2, 4, 8]" $ VInt 15
    shouldEvaluateTo "Array.sum [1.0, 2.0, 4.0, 8.0]" $ VDouble 15
    shouldEvaluateTo "open Array in range 4 13" $ VArray (map VInt [4 .. 13])
    shouldEvaluateTo "open Time in Array.sum [seconds 2, hours 5]" $ VEpochTime 18002
    -- Option type
    shouldEvaluateTo "Array.sum (Array.keepSomes [Some 3.0, None, Some 4.0])" $ VDouble 7
    shouldEvaluateTo "Array.findFirstSome [None, Some 3.0, None, Some 4.0]" $ VOne $ VDouble 3
    shouldEvaluateTo "Array.findLastSome [None, Some 3.0, None, Some 4.0]" $ VOne $ VDouble 4
    shouldEvaluateTo "Array.findFirstAndLastSome [None, Some 3.0, None, Some 4.0]" $ VOne $ VTuple [VDouble 3, VDouble 4]
    shouldEvaluateTo "Option.map (fun x -> x + 2) (Some 4.0)" $ VOne $ VDouble 6
    shouldEvaluateToWithTRep typeInt "Option.map (fun x -> x + 2) None" VEmpty
    shouldEvaluateTo "fromOption 0 (Some 4.0)" $ VDouble 4
    shouldEvaluateTo "fromOption 0.0 None" $ VDouble 0
    shouldEvaluateTo "(Some 4.0) ? 0" $ VDouble 4
    shouldEvaluateTo "None ? 0.0" $ VDouble 0
    shouldEvaluateTo "Option.reduce (fun d -> d + 2) 0.0 (Some 4)" $ VDouble 6
    shouldEvaluateTo "Option.reduce (fun d -> d + 2) 0.0 (Some 4.0)" $ VDouble 6
    shouldEvaluateTo "Option.reduce (fun d -> d + 2) 0 (Some 4.0)" $ VDouble 6
    shouldEvaluateTo "Option.reduce (fun d -> d + 2) 0.0 None" $ VDouble 0
    -- Time
    shouldEvaluateTo "Time.seconds 5" $ VEpochTime 5
    shouldEvaluateTo "Time.minutes 5 == 5 * Time.seconds 60" vTrue
    shouldEvaluateTo "Time.hours 5 == 5 * Time.minutes 60" vTrue
    shouldEvaluateTo "Time.days 5 == 5 * Time.hours 24" vTrue
    shouldEvaluateTo "Time.weeks 5 == 5 * Time.days 7" vTrue
    shouldEvaluateTo "open Time in let ?now = toTime (seconds 4000) in intervalEvery (seconds 4) ?now (?now + seconds 10)" $
      VArray [VEpochTime 4000, VEpochTime 4004, VEpochTime 4008]
    shouldEvaluateTo "open Time in hour (toTime (hours 3 + seconds 400)) == toTime (hours 3)" vTrue
    shouldEvaluateTo "open Time in day (toTime (days 3 + hours 22)) == toTime (days 3)" vTrue
    shouldEvaluateTo "open Time in month (toTime (days 66)) == toTime (days 59)" vTrue
    shouldEvaluateTo "open Time in year (toTime (days 367))" $ VEpochTime (60 * 60 * 24 * 365)
    shouldEvaluateTo
      "open Time in let ?now = (toTime (seconds 66666)) in secondsBefore ?now 44 == ?now - (seconds 44)"
      vTrue
    shouldEvaluateTo
      "open Time in let ?now = (toTime (minutes 66666)) in minutesBefore ?now 44 == ?now - (minutes 44)"
      vTrue
    shouldEvaluateTo
      "open Time in let ?now = (toTime (hours 66666)) in hoursBefore ?now 44 == ?now - (hours 44)"
      vTrue
    shouldEvaluateTo
      "open Time in let ?now = (toTime (days 66666)) in daysBefore ?now 44 == ?now - (days 44)"
      vTrue
    shouldEvaluateTo
      "open Time in let ?now = (toTime (weeks 66666)) in weeksBefore ?now 44 == ?now - (weeks 44)"
      vTrue
    shouldEvaluateTo
      -- 2 months before 1970-04-11 is 1970-02-11
      "open Time in monthsBefore (toTime (days 100 + hours 22)) 2 == toTime (days 41 + hours 22)"
      vTrue
    shouldEvaluateTo
      -- 3 months before 1970-05-31 is 1970-02-28 because of clipping
      "open Time in monthsBefore (toTime (days 150 + hours 22)) 3 == toTime (days 58 + hours 22)"
      vTrue
    shouldEvaluateTo
      -- 2 years before 1972-04-11 is 1970-04-11
      "open Time in yearsBefore (toTime (days 831 + hours 22)) 2 == toTime (days 100 + hours 22)"
      vTrue
    shouldEvaluateTo
      -- 2 years before 1972-02-29 is 1970-02-28 because of clipping
      "open Time in yearsBefore (toTime (days 789 + hours 22)) 2 == toTime (days 58 + hours 22)"
      vTrue
    shouldEvaluateTo "Time.formatTime (Time.toTime (Time.seconds 0)) \"%H:%M:%S\"" $ VText "00:00:00"
    shouldEvaluateTo "Time.formatTime (Time.toTime (Time.seconds 0)) \"%c\"" $ VText "Thu Jan  1 00:00:00 UTC 1970"
    -- Text
    shouldEvaluateTo "Text.append \"hello \" \"world\"" $ VText "hello world"
    shouldEvaluateTo "Text.length \"hello\"" $ VInt 5
    shouldEvaluateTo "Text.strip \" hello \"" $ VText "hello"
    shouldEvaluateTo "Text.splitAt 5 \"hello world\"" $ VTuple [VText "hello", VText " world"]
    -- Miscellaneous
    shouldEvaluateTo "\"hello world\"" $ VText "hello world"
    shouldEvaluateInEnvTo
      Map.empty
      (Map.fromList [(ExtIdent $ Right "x", VInt 5)])
      [TypeRep dummyPos typeInt]
      "?x + 2"
      (VInt 7)
    shouldEvaluateInEnvTo
      Map.empty
      (Map.fromList [(ExtIdent $ Right "x", VInt 5)])
      [TypeRep dummyPos typeInt]
      "let f = fun x -> ?x + 2 in f 0"
      (VInt 7)
    shouldEvaluateTo "let ?x = 3.2 in ?x + 2" $ VDouble 5.2
    shouldEvaluateTo "let x = 3.2 in x + 2" $ VDouble 5.2
    shouldEvaluateTo "if #true then Some 2.0 else None" $ VOne (VDouble 2)
    shouldEvaluateTo "match #true with { | #true -> #false | _ -> #true}" vFalse
    shouldEvaluateTo "match 3.9 - 2.2 with { 0.0 -> #false | _ -> #true}" vTrue
    shouldEvaluateTo "`hello ${Array.range 1 10}`" $ VText "hello [1,2,3,4,5,6,7,8,9,10]"
    shouldEvaluateTo "`${id}`" $ VText "<<function>>"
    shouldEvaluateTo "`hello\nworld${`I am ${\"nested\"}`}`" $ VText "hello\nworldI am nested"
    shouldEvaluateTo "[x | x <- 1 .. 10]" $ VArray (map VInt [1 .. 10])
    shouldEvaluateTo "[x | x <- 1 .. 10, if x % 2 == 0]" $ VArray (map VInt [2, 4, 6, 8, 10])
    shouldThrowRuntimeError "assert #false in ()" $ Just AssertionFailed
    shouldEvaluateTo "assert #true in ()" $ VTuple []
  where
    vTrue = VEnum enumBoolHash (Ident "true")
    vFalse = VEnum enumBoolHash (Ident "false")
    shouldEvaluateInEnvTo localEnv implEnv typeReps str (v :: Value TestCustomValue (ExceptT EvalError IO)) =
      it ("\"" <> unpack str <> "\" should evaluate to " <> (unpack $ renderPretty v)) $
        case parseExpr baseOpsTable builtinModulesOpsTable str of
          Left err -> expectationFailure $ "Failed parsing with: " <> (prettyError $ fst $ NEList.head err)
          Right (ast, _) -> do
            case pinExpr builtinModulesPinMap ast of
              Left err -> expectationFailure $ "Failed inference with: " <> show err
              Right pinnedAST ->
                case inferExpr builtinModules pinnedAST of
                  Left err -> expectationFailure $ "Failed inference with: " <> show err
                  Right (pinnedAST', ty, _) -> do
                    let trmEnv = ((localEnv, mempty) <>) <$> builtinModulesTerms
                    let expr = foldl App pinnedAST' typeReps
                    (liftIO $ runEvalIO trmEnv implEnv $ bimap pinnedToMaybe id expr) >>= \case
                      Left err ->
                        expectationFailure $
                          "Failed eval with: " <> show err
                            <> "\nType: "
                            <> show ty
                            <> "\nExpr: "
                            <> show (bimap (const ()) (const ()) expr)
                      Right v' -> (renderPretty v') `shouldBe` (renderPretty v)
    shouldEvaluateTo = shouldEvaluateInEnvTo Map.empty Map.empty []
    shouldEvaluateToWithTRep typ = shouldEvaluateInEnvTo Map.empty Map.empty [TypeRep dummyPos typ]
    shouldEvaluateToWithTReps typs = shouldEvaluateInEnvTo Map.empty Map.empty (map (TypeRep dummyPos) typs)
    shouldThrowRuntimeError str merr =
      it ("\"" <> unpack str <> "\" should throw a runtime error") $
        case parseExpr baseOpsTable builtinModulesOpsTable str of
          Left err -> expectationFailure $ "Failed parsing with: " <> (prettyError $ fst $ NEList.head err)
          Right (ast, _) -> do
            case pinExpr builtinModulesPinMap ast of
              Left err -> expectationFailure $ "Failed inference with: " <> show err
              Right pinnedAST ->
                case inferExpr builtinModules pinnedAST of
                  Left err -> expectationFailure $ "Failed inference with: " <> show err
                  Right _ -> do
                    let trmEnv = builtinModulesTerms
                    (liftIO $ runEvalIO trmEnv mempty $ bimap pinnedToMaybe id pinnedAST) >>= \case
                      Left err' -> case merr of
                        Nothing -> pure ()
                        Just err -> err' `shouldBe` err
                      Right _ -> expectationFailure $ "Should not evaluate."
    dummyPos = initialPos "dummy"
