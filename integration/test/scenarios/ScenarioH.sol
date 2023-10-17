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

contract ScenarioH is ScenarioSetup, AssertionHelpers, Actions, Checks {
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

        datedIrsProxy.createMarket({ marketId: marketId, quoteToken: address(mockGlpToken), marketType: "linear" });
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
                oracleAddress: address(glpRateOracle),
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
        observedTicks[0] = initTick;
        observedTicks[1] = initTick;
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

        mockGlpRewardRouter.setAPY(wrap(0.1e18));
        mockGlpRewardRouter.setStartTime(Time.blockTimestampTruncated() - 86_400);
    }

    function test_scenario_H() public {
        setConfigs();
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(18));

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16_096, "current tick");

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: -1000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(44_877_798_236_844_817_030), "executedQuote");
                assertEq(annualizedNotional, -1_000_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 4_523_743_141_928_824_253_103,
                expectedUnfilledBaseShort: 5_476_256_858_071_175_746_896,
                expectedUnfilledQuoteLong: 270_343_108_629_547_653_771,
                expectedUnfilledQuoteShort: 187_198_505_034_284_815_184
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 999_999_999_999_999_999_999,
                expectedQuoteBalance: -44_877_798_236_844_817_029,
                expectedAccruedInterest: 0
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_000_000_000_000_000_000_000,
                expectedQuoteBalance: 44_877_798_236_844_817_030,
                expectedAccruedInterest: 0
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_227, "current tick");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.125)
        vm.warp(start + 86_400 * 365 / 8);

        // t = 0.125: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: -1000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(41_887_571_120_799_625_000), "executedQuote");
                assertEq(annualizedNotional, -875_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 5_022_797_400_575_177_857_252,
                expectedUnfilledBaseShort: 4_977_202_599_424_822_142_746,
                expectedUnfilledQuoteLong: 294_242_704_172_179_489_241,
                expectedUnfilledQuoteShort: 166_293_235_043_531_099_974
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_499_999_999_999_999_999_999,
                expectedQuoteBalance: -65_821_583_797_244_629_529,
                expectedAccruedInterest: 6_890_275_220_394_397_871
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 5_022_797_400_575_177_857_252,
                expectedUnfilledBaseShort: 4_977_202_599_424_822_142_746,
                expectedUnfilledQuoteLong: 294_242_704_172_179_489_241,
                expectedUnfilledQuoteShort: 166_293_235_043_531_099_974
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 499_999_999_999_999_999_999,
                expectedQuoteBalance: -20_943_785_560_399_812_499,
                expectedAccruedInterest: 0
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2_000_000_000_000_000_000_000,
                expectedQuoteBalance: 86_765_369_357_644_442_030,
                expectedAccruedInterest: -6_890_275_220_394_397_872
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_807, "current tick");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.25)
        vm.warp(start + 86_400 * 365 / 4);

        invariantCheck();

        // t = 0.25: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: 500 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e18, "executedBase");
                assertEq(executedQuote, int256(-23_630_112_017_313_873_500), "executedQuote");
                assertEq(annualizedNotional, 375_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 9_712_945_257_243_711_512_792,
                expectedUnfilledBaseShort: 10_287_054_742_756_288_487_207,
                expectedUnfilledQuoteLong: 572_763_222_123_525_687_145,
                expectedUnfilledQuoteShort: 346_312_759_044_455_638_696
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_166_666_666_666_666_666_666,
                expectedQuoteBalance: -50_068_175_785_702_047_196,
                expectedAccruedInterest: 17_412_577_245_738_819_180
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 4_856_472_628_621_855_756_396,
                expectedUnfilledBaseShort: 5_143_527_371_378_144_243_603,
                expectedUnfilledQuoteLong: 286_381_611_061_762_843_572,
                expectedUnfilledQuoteShort: 173_156_379_522_227_819_348
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 333_333_333_333_333_333_333,
                expectedQuoteBalance: -13_067_081_554_628_521_333,
                expectedAccruedInterest: 3_632_026_804_950_023_427
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_500_000_000_000_000_000_000,
                expectedQuoteBalance: 63_135_257_340_330_568_530,
                expectedAccruedInterest: -21_044_604_050_688_842_619
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_946, "current tick");

        /////////////////////////// 3 / 8 ///////////////////////////

        // advance time (t = 0.375)
        vm.warp(start + 86_400 * 365 * 3 / 8);

        invariantCheck();

        // t = 0.375: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: -1000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(41_107_183_376_255_950_000), "executedQuote");
                assertEq(annualizedNotional, -625_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 10_213_993_447_040_870_265_238,
                expectedUnfilledBaseShort: 9_786_006_552_959_129_734_760,
                expectedUnfilledQuoteLong: 596_367_036_037_223_606_839,
                expectedUnfilledQuoteShort: 325_715_234_269_540_661_190
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_666_666_666_666_666_666_665,
                expectedQuoteBalance: -70_621_767_473_830_022_195,
                expectedAccruedInterest: 25_737_388_605_859_396_606
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 10_213_993_447_040_870_265_238,
                expectedUnfilledBaseShort: 9_786_006_552_959_129_734_760,
                expectedUnfilledQuoteLong: 596_367_036_037_223_606_839,
                expectedUnfilledQuoteShort: 325_715_234_269_540_661_190
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 833_333_333_333_333_333_332,
                expectedQuoteBalance: -33_620_673_242_756_496_332,
                expectedAccruedInterest: 6_165_308_277_288_124_927
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2_500_000_000_000_000_000_000,
                expectedQuoteBalance: 104_242_440_716_586_518_530,
                expectedAccruedInterest: -31_902_696_883_147_521_553
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14_737, "current tick");

        /////////////////////////// 4 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 / 2);

        invariantCheck();

        // t = 0.5: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: 5000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, 5000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(-242_696_027_821_688_342_382), "executedQuote");
                assertEq(annualizedNotional, 2_500_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_319_662_811_789_522_263_691,
                expectedUnfilledBaseShort: 17_680_337_188_210_477_736_308,
                expectedUnfilledQuoteLong: 748_863_632_024_131_973_782,
                expectedUnfilledQuoteShort: 616_251_809_283_383_736_452
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_333_333_333_333_333_333_334,
                expectedQuoteBalance: 74_995_849_219_182_983_234,
                expectedAccruedInterest: 37_743_001_004_963_977_167
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 8_213_108_541_193_014_842_460,
                expectedUnfilledBaseShort: 11_786_891_458_806_985_157_538,
                expectedUnfilledQuoteLong: 499_242_421_349_421_315_854,
                expectedUnfilledQuoteShort: 410_834_539_522_255_824_301
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_166_666_666_666_666_666_666,
                expectedQuoteBalance: 63_457_737_885_918_840_619,
                expectedAccruedInterest: 12_379_390_788_610_229_551
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_500_000_000_000_000_000_000,
                expectedQuoteBalance: -138_453_587_105_101_823_852,
                expectedAccruedInterest: -50_122_391_793_574_206_737
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_585, "current tick");

        /////////////////////////// 5 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 5 / 8);

        invariantCheck();

        // t = 0.625: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: 500 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e18, "executedBase");
                assertEq(executedQuote, int256(-25_341_285_528_301_014_000), "executedQuote");
                assertEq(annualizedNotional, 187_500_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_070_645_555_169_188_029_470,
                expectedUnfilledBaseShort: 17_929_354_444_830_811_970_528,
                expectedUnfilledQuoteLong: 736_242_309_807_429_751_994,
                expectedUnfilledQuoteShort: 627_379_027_960_363_951_941
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_583_333_333_333_333_333_334,
                expectedQuoteBalance: 87_666_491_983_333_490_234,
                expectedAccruedInterest: 30_450_815_490_695_183_404
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_070_645_555_169_188_029_470,
                expectedUnfilledBaseShort: 17_929_354_444_830_811_970_528,
                expectedUnfilledQuoteLong: 736_242_309_807_429_751_994,
                expectedUnfilledQuoteShort: 627_379_027_960_363_951_941
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_416_666_666_666_666_666_665,
                expectedQuoteBalance: 76_128_380_650_069_347_618,
                expectedAccruedInterest: 5_728_274_691_016_751_315
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 3_000_000_000_000_000_000_000,
                expectedQuoteBalance: -163_794_872_633_402_837_852,
                expectedAccruedInterest: -36_179_090_181_711_934_718
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_657, "current tick");

        /////////////////////////// 6 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 6 / 8);

        invariantCheck();

        // t = 0.75: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: -1000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(44_560_021_450_814_117_000), "executedQuote");
                assertEq(annualizedNotional, -250_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 16_666_755_894_264_964_893_957,
                expectedUnfilledBaseShort: 23_333_244_105_735_035_106_041,
                expectedUnfilledQuoteLong: 1_010_605_548_599_000_602_347,
                expectedUnfilledQuoteShort: 810_991_606_015_627_279_689
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_011_904_761_904_761_904_763,
                expectedQuoteBalance: 62_203_622_582_868_280_520,
                expectedAccruedInterest: 21_617_460_321_945_203_017
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 12_500_066_920_698_723_670_468,
                expectedUnfilledBaseShort: 17_499_933_079_301_276_329_531,
                expectedUnfilledQuoteLong: 757_954_161_449_250_451_760,
                expectedUnfilledQuoteShort: 608_243_704_511_720_459_767
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -988_095_238_095_238_095_238,
                expectedQuoteBalance: 57_031_228_599_720_440_334,
                expectedAccruedInterest: -2_464_011_061_057_913_564
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_000_000_000_000_000_000_000,
                expectedQuoteBalance: -119_234_851_182_588_720_852,
                expectedAccruedInterest: -19_153_449_260_887_289_449
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_533, "current tick");

        /////////////////////////// 7 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86_400 * 365 * 7 / 8);

        invariantCheck();

        // t = 0.875: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e18,
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
                baseAmount: -5000 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -5000 * 1e18, "executedBase");
                assertEq(executedQuote, int256(215_123_144_964_107_657_778), "executedQuote");
                assertEq(annualizedNotional, -625_000_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_716_019_583_838_780,
                expectedUnfilledBaseShort: 20_836_083_283_980_416_161_219,
                expectedUnfilledQuoteLong: 1_133_031_620_415_917_748_753,
                expectedUnfilledQuoteShort: 703_548_499_129_237_854_071
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_488_095_238_095_238_095_237,
                expectedQuoteBalance: -45_357_949_899_185_548_369,
                expectedAccruedInterest: 16_744_103_620_994_214_274
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_716_019_583_838_780,
                expectedUnfilledBaseShort: 20_836_083_283_980_416_161_219,
                expectedUnfilledQuoteLong: 1_133_031_620_415_917_748_753,
                expectedUnfilledQuoteShort: 703_548_499_129_237_854_071
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_511_904_761_904_761_904_761,
                expectedQuoteBalance: -50_530_343_882_333_388_554,
                expectedAccruedInterest: -7_686_297_962_283_334_730
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3_000_000_000_000_000_000_000,
                expectedQuoteBalance: 95_888_293_781_518_936_926,
                expectedAccruedInterest: -9_057_805_658_710_879_555
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_001, "current tick");

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
                baseAmount: -500 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -500 * 1e18, "executedBase");
                assertEq(executedQuote, int256(20_848_891_939_506_194_500), "executedQuote");
                assertEq(annualizedNotional, -31_250_000_000_000_000_000, "annualizedNotional");
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
                baseAmount: 500 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, 500 * 1e18, "executedBase");
                assertEq(executedQuote, int256(-23_848_891_939_506_194_500), "executedQuote");
                assertEq(annualizedNotional, 31_250_000_000_000_000_000, "annualizedNotional");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_716_019_583_838_780,
                expectedUnfilledBaseShort: 20_836_083_283_980_416_161_219,
                expectedUnfilledQuoteLong: 1_133_031_620_415_917_748_753,
                expectedUnfilledQuoteShort: 703_548_499_129_237_854_071
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_488_095_238_095_238_095_227,
                expectedQuoteBalance: -43_857_949_899_185_548_359,
                expectedAccruedInterest: 23_209_826_990_390_355_596
            });

            checkPnLComponents(datedIrsProxy, marketId, 1, 0, 0);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 19_163_916_716_019_583_838_780,
                expectedUnfilledBaseShort: 20_836_083_283_980_416_161_219,
                expectedUnfilledQuoteLong: 1_133_031_620_415_917_748_753,
                expectedUnfilledQuoteShort: 703_548_499_129_237_854_071
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 1_511_904_761_904_761_904_751,
                expectedQuoteBalance: -49_030_343_882_333_388_544,
                expectedAccruedInterest: -1_395_039_693_024_409_590
            });

            checkPnLComponents(datedIrsProxy, marketId, 2, 0, 0);
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3_000_000_000_000_000_000_000,
                expectedQuoteBalance: 92_888_293_781_518_936_926,
                expectedAccruedInterest: -21_814_787_297_365_945_998
            });

            checkPnLComponents(datedIrsProxy, marketId, 3, 0, 0);
        }

        /////////////////////////// SETTLEMENT ///////////////////////////
        invariantCheck();

        vm.warp(start + 86_400 * 365);

        int256[] memory settlementCashflows = new int256[](3);

        // settle account 1
        settlementCashflows[0] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 1 });
        assertEq(settlementCashflows[0], 29_769_300_359_786_496_927, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 2 });
        assertEq(settlementCashflows[1], 4_989_968_576_234_515_520, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 3 });
        assertEq(settlementCashflows[2], -34_759_268_936_021_012_440, "settlement cashflow 3");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflows.length; i++) {
                netSettlementCashflow += settlementCashflows[i];
            }

            assertAlmostEq(netSettlementCashflow, int256(0), 10, "net settlement cashflow");
        }

        invariantCheck();
    }
}
