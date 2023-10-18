pragma solidity >=0.8.19;

import { Actions } from "./utils/Actions.sol";
import { AssertionHelpers } from "./utils/AssertionHelpers.sol";
import { Checks } from "./utils/Checks.sol";
import { Constants } from "./utils/Constants.sol";
import { ScenarioSetup } from "./utils/ScenarioSetup.sol";

import { DatedIrsProxy } from "../../src/proxies/DatedIrs.sol";
import { VammProxy } from "../../src/proxies/Vamm.sol";

import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { Market } from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";

import { DatedIrsVamm } from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { VammTicks } from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";

import { ud, wrap, unwrap } from "@prb/math/UD60x18.sol";

contract ScenarioG is ScenarioSetup, AssertionHelpers, Actions, Checks {
    uint128 public marketId;
    uint32 public maturityTimestamp;
    int24 public initTick;

    function getDatedIrsProxy() internal view override returns (DatedIrsProxy) {
        return datedIrsProxy;
    }

    function getCoreProxyAddress() internal view override returns (address) {
        return mockCoreProxy;
    }

    function getVammProxy() internal view override returns (VammProxy) {
        return vammProxy;
    }

    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal pure override returns (uint32) {
        return 7 * 86_400;
    }

    function invariantCheck() internal {
        uint128[] memory accountIds = new uint128[](3);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;

        checkTotalFilledBalances(datedIrsProxy, marketId, maturityTimestamp, accountIds);
    }

    function setUp() public {
        super.datedIrsSetup();
        marketId = 1;
        maturityTimestamp = uint32(block.timestamp) + 365 * 86_400; // in 1 year
        initTick = -16_096; // 5%
    }

    function setConfigs() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({ marketId: marketId, quoteToken: address(mockUsdc), marketType: "compounding" });

        datedIrsProxy.setMarketConfiguration(
            marketId,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketId, maturityTimestamp), // 7 days
                markPriceBand: ud(0.045e18), // 4.5%
                takerPositionsPerAccountLimit: 100,
                positionSizeUpperLimit: 1e27, // 1B
                positionSizeLowerLimit: 0,
                openInterestUpperLimit: 1e27 // 1B
             })
        );

        datedIrsProxy.setRateOracleConfiguration(
            marketId,
            Market.RateOracleConfiguration({
                oracleAddress: address(aaveV3RateOracle),
                maturityIndexCachingWindowInSeconds: 1e27 // 1B
             })
        );

        //////// VAMM CONFIGURATION ////////

        vammProxy.setPoolConfiguration(
            PoolConfiguration.Data({
                marketManagerAddress: address(datedIrsProxy),
                makerPositionsPerAccountLimit: 1e27 // 1B
             })
        );

        datedIrsProxy.setMarketMaturityConfiguration(
            marketId,
            maturityTimestamp,
            Market.MarketMaturityConfiguration({
                riskMatrixRowId: 0,
                tenorInSeconds: 0,
                phi: ud(0.0001e18), // vol / volume = 0.01
                beta: ud(0.5e18)
            })
        );

        DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
            maturityTimestamp: maturityTimestamp,
            maxLiquidityPerTick: type(uint128).max,
            tickSpacing: 60,
            marketId: marketId
        });

        DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
            spread: ud(0.003e18), // 0.3%
            minSecondsBetweenOracleObservations: 10,
            minTickAllowed: VammTicks.DEFAULT_MIN_TICK,
            maxTickAllowed: VammTicks.DEFAULT_MAX_TICK,
            inactiveWindowBeforeMaturity: 86_400
        });

        // ensure the current time > 7 days
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86_400 * 8);
        times[1] = uint32(block.timestamp - 86_400 * 4);
        int24[] memory observedTicks = new int24[](2);
        observedTicks[0] = -16_096;
        observedTicks[1] = -16_096;
        vammProxy.createVamm({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTick),
            times: times,
            observedTicks: observedTicks,
            config: immutableConfig,
            mutableConfig: mutableConfig
        });

        vammProxy.increaseObservationCardinalityNext(marketId, maturityTimestamp, 16);

        // FEATURE FLAGS
        datedIrsProxy.addToFeatureFlagAllowlist(
            datedIrsProxy.getMarketEnabledFeatureFlagId(marketId, maturityTimestamp), mockCoreProxy
        );

        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));

        vm.stopPrank();

        aaveLendingPool.setAPY(wrap(0.02e18));
        aaveLendingPool.setStartTime(Time.blockTimestampTruncated());
    }

    function test_scenario_G() public {
        setConfigs();
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16_096, "current tick");

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -1000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(44_877_797), "executedQuote");
                assertEq(annualizedNotional, -1_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 4_523_743_141,
                expectedUnfilledBaseShort: 5_476_256_858,
                expectedUnfilledQuoteLong: 270_343_108,
                expectedUnfilledQuoteShort: 187_198_505
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 999_999_999,
                expectedQuoteBalance: -44_877_796,
                expectedRealizedPnL: 0
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 44_877_797,
                expectedRealizedPnL: 0
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_227, "current tick");
        assertEq(1e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.125)
        vm.warp(start + 86_400 * 365 / 8);

        // t = 0.125: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.125: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -1000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(41_992_290), "executedQuote");
                assertEq(annualizedNotional, -877_187_500, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 5_022_797_400,
                expectedUnfilledBaseShort: 4_977_202_599,
                expectedUnfilledQuoteLong: 294_978_310,
                expectedUnfilledQuoteShort: 166_708_968
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_499_999_999,
                expectedQuoteBalance: -65_873_941,
                expectedRealizedPnL: -3_109_724
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 5_022_797_400,
                expectedUnfilledBaseShort: 4_977_202_599,
                expectedUnfilledQuoteLong: 294_978_310,
                expectedUnfilledQuoteShort: 166_708_968
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 499_999_999,
                expectedQuoteBalance: -20_996_144,
                expectedRealizedPnL: 0
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2_000_000_000,
                expectedQuoteBalance: 86_870_087,
                expectedRealizedPnL: 3_109_724
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_807, "current tick");
        assertEq(1.0025e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.25)
        vm.warp(start + 86_400 * 365 / 4);

        invariantCheck();

        // t = 0.25: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.25: account 3 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: 500 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-23_748_262), "executedQuote");
                assertEq(annualizedNotional, 376_875_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 9_712_945_257,
                expectedUnfilledBaseShort: 10_287_054_742,
                expectedUnfilledQuoteLong: 575_627_038,
                expectedUnfilledQuoteShort: 348_044_322
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_166_666_666,
                expectedQuoteBalance: -50_041_767,
                expectedRealizedPnL: -7_593_967
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 4_856_472_628,
                expectedUnfilledBaseShort: 5_143_527_371,
                expectedUnfilledQuoteLong: 287_813_519,
                expectedUnfilledQuoteShort: 174_022_161
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 333_333_333,
                expectedQuoteBalance: -13_080_057,
                expectedRealizedPnL: -1_374_528
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_500_000_000,
                expectedQuoteBalance: 63_121_825,
                expectedRealizedPnL: 8_968_484
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_946, "current tick");
        assertEq(1.005e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 3 / 8 ///////////////////////////

        // advance time (t = 0.375)
        vm.warp(start + 86_400 * 365 * 3 / 8);

        invariantCheck();

        // t = 0.375: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.375: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -1000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(41_415_487), "executedQuote");
                assertEq(annualizedNotional, -629_687_500, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 10_213_993_446,
                expectedUnfilledBaseShort: 9_786_006_552,
                expectedUnfilledQuoteLong: 600_839_788,
                expectedUnfilledQuoteShort: 328_158_098
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_666_666_665,
                expectedQuoteBalance: -70_749_509,
                expectedRealizedPnL: -10_932_510
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 10_213_993_446,
                expectedUnfilledBaseShort: 9_786_006_552,
                expectedUnfilledQuoteLong: 600_839_788,
                expectedUnfilledQuoteShort: 328_158_098
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 833_333_332,
                expectedQuoteBalance: -33_787_800,
                expectedRealizedPnL: -2_176_182
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2_500_000_000,
                expectedQuoteBalance: 104_537_312,
                expectedRealizedPnL: 13_108_712
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_737, "current tick");
        assertEq(1.0075e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 4 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 / 2);

        invariantCheck();

        // t = 0.5: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.5: account 3 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: 5000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 5000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-245_122_987), "executedQuote");
                assertEq(annualizedNotional, 2_525_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_319_662_811,
                expectedUnfilledBaseShort: 17_680_337_188,
                expectedUnfilledQuoteLong: 756_352_268,
                expectedUnfilledQuoteShort: 622_414_327
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_333_333_334,
                expectedQuoteBalance: 76_324_283,
                expectedRealizedPnL: -15_609_532
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 8_213_108_541,
                expectedUnfilledBaseShort: 11_786_891_458,
                expectedUnfilledQuoteLong: 504_234_845,
                expectedUnfilledQuoteShort: 414_942_884
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_166_666_666,
                expectedQuoteBalance: 64_261_394,
                expectedRealizedPnL: -4_316_323
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_500_000_000,
                expectedQuoteBalance: -140_585_675,
                expectedRealizedPnL: 19_925_876
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_585, "current tick");
        assertEq(1.01e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 5 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 5 / 8);

        invariantCheck();

        // t = 0.625: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.625: account 3 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: 500 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-25_658_051), "executedQuote");
                assertEq(annualizedNotional, 189_843_750, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_070_645_555,
                expectedUnfilledBaseShort: 17_929_354_444,
                expectedUnfilledQuoteLong: 745_445_338,
                expectedUnfilledQuoteShort: 635_221_265
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_583_333_334,
                expectedQuoteBalance: 89_153_308,
                expectedRealizedPnL: -9_402_350
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_070_645_555,
                expectedUnfilledBaseShort: 17_929_354_444,
                expectedUnfilledQuoteLong: 745_445_338,
                expectedUnfilledQuoteShort: 635_221_265
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_416_666_665,
                expectedQuoteBalance: 77_090_419,
                expectedRealizedPnL: 799_683
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 3_000_000_000,
                expectedQuoteBalance: -166_243_726,
                expectedRealizedPnL: 8_602_667
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_657, "current tick");
        assertEq(1.0125e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 6 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 6 / 8);

        invariantCheck();

        // t = 0.75: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.75: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -1000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(45_228_421), "executedQuote");
                assertEq(annualizedNotional, -253_750_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 16_666_755_894,
                expectedUnfilledBaseShort: 23_333_244_105,
                expectedUnfilledQuoteLong: 1_025_764_631,
                expectedUnfilledQuoteShort: 823_156_480
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_011_904_763,
                expectedQuoteBalance: 63_308_497,
                expectedRealizedPnL: -2_216_499
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_500_066_920,
                expectedUnfilledBaseShort: 17_499_933_079,
                expectedUnfilledQuoteLong: 769_323_473,
                expectedUnfilledQuoteShort: 617_367_360
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -988_095_238,
                expectedQuoteBalance: 57_706_811,
                expectedRealizedPnL: 6_894_321
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_000_000_000,
                expectedQuoteBalance: -121_015_305,
                expectedRealizedPnL: -4_677_798
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_533, "current tick");
        assertEq(1.015e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 7 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 7 / 8);

        invariantCheck();

        // t = 0.875: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0.875: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -5000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -5000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(218_887_799), "executedQuote");
                assertEq(annualizedNotional, -635_937_500, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_715,
                expectedUnfilledBaseShort: 20_836_083_283,
                expectedUnfilledQuoteLong: 1_152_859_673,
                expectedUnfilledQuoteShort: 715_860_597
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_488_095_237,
                expectedQuoteBalance: -46_135_403,
                expectedRealizedPnL: 3_167_301
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_715,
                expectedUnfilledBaseShort: 20_836_083_283,
                expectedUnfilledQuoteLong: 1_152_859_673,
                expectedUnfilledQuoteShort: 715_860_597
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_511_904_761,
                expectedQuoteBalance: -51_737_088,
                expectedRealizedPnL: 11_637_435
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3_000_000_000,
                expectedQuoteBalance: 97_872_494,
                expectedRealizedPnL: -14_804_711
            });
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_001, "current tick");
        assertEq(1.0175e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 15 / 16 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 15 / 16);

        invariantCheck();

        // t = 0.9375: account 3 (FT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: -500 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -500 * 1e6, "executedBase");
                assertEq(executedQuote, int256(21_239_808), "executedQuote");
                assertEq(annualizedNotional, -31_835_937, "annualizedNotional");
            }
        }

        // t = 0.9375: account 3 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: 500 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-24_296_058), "executedQuote");
                assertEq(annualizedNotional, 31_835_937, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_715,
                expectedUnfilledBaseShort: 20_836_083_283,
                expectedUnfilledQuoteLong: 1_154_275_963,
                expectedUnfilledQuoteShort: 716_740_033
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_488_095_237,
                expectedQuoteBalance: -44_607_278,
                expectedRealizedPnL: 2_143_957
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_715,
                expectedUnfilledBaseShort: 20_836_083_283,
                expectedUnfilledQuoteLong: 1_154_275_963,
                expectedUnfilledQuoteShort: 716_740_033
            });

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_511_904_761,
                expectedQuoteBalance: -50_208_963,
                expectedRealizedPnL: 10_293_749
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalancesWithoutUPnL({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3_000_000_000,
                expectedQuoteBalance: 94_816_244,
                expectedRealizedPnL: -12_437_681
            });
        }

        /////////////////////////// SETTLEMENT ///////////////////////////
        invariantCheck();

        vm.warp(start + 86_400 * 365);

        int256[] memory settlementCashflows = new int256[](3);

        // settle account 1
        settlementCashflows[0] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 1 });
        assertEq(settlementCashflows[0], 1_216_111, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 2 });
        assertEq(settlementCashflows[1], 9_045_559, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 3 });
        assertEq(settlementCashflows[2], -10_261_665, "settlement cashflow 3");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflows.length; i++) {
                netSettlementCashflow += settlementCashflows[i];
            }

            assertAlmostEq(netSettlementCashflow, int256(0), 5, "net settlement cashflow");
        }

        invariantCheck();
    }
}
