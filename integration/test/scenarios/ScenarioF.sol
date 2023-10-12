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

import { ud60x18, wrap, unwrap } from "@prb/math/UD60x18.sol";

contract ScenarioF is ScenarioSetup, AssertionHelpers, Actions, Checks {
    uint128 public marketIdAave;
    uint128 public marketIdGlp;
    uint32 public maturityTimestampAave;
    uint32 public maturityTimestampGlp;
    int24 public initTickAave;
    int24 public initTickGlp;

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

    function invariantCheck(uint128 marketId, uint32 maturityTimestamp) internal {
        uint128[] memory accountIds = new uint128[](3);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;

        checkTotalFilledBalances(datedIrsProxy, marketId, maturityTimestamp, accountIds);
    }

    function setUp() public {
        super.datedIrsSetup();
        marketIdAave = 1;
        marketIdGlp = 2;
        maturityTimestampAave = uint32(block.timestamp) + 365 * 86_400; // in 1 year
        maturityTimestampGlp = uint32(block.timestamp) + 365 * 86_400 / 2; // in 1/2 years
        initTickAave = -16_096; // 5%
        initTickGlp = -23_027; // 10%
    }

    function setConfigs_Aave_market() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({ marketId: marketIdAave, quoteToken: address(mockUsdc), marketType: "compounding" });
        datedIrsProxy.setMarketConfiguration(
            marketIdAave,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketIdAave, maturityTimestampGlp), // 7 days
                markPriceBand: ud60x18(0.045e18), // 1%
                takerPositionsPerAccountLimit: 100,
                positionSizeUpperLimit: 1e27, // 1B
                positionSizeLowerLimit: 0,
                openInterestUpperLimit: 1e27 // 1B
             })
        );
        datedIrsProxy.setRateOracleConfiguration(
            marketIdAave,
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

        DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
            maturityTimestamp: maturityTimestampAave,
            maxLiquidityPerTick: type(uint128).max,
            tickSpacing: 60,
            marketId: marketIdAave
        });

        DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
            priceImpactPhi: ud60x18(0.0001e18), // vol / volume = 0.01
            spread: ud60x18(0.003e18), // 0.3%
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
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTickAave),
            times: times,
            observedTicks: observedTicks,
            config: immutableConfig,
            mutableConfig: mutableConfig
        });
        vammProxy.increaseObservationCardinalityNext(marketIdAave, maturityTimestampAave, 16);

        // FEATURE FLAGS
        datedIrsProxy.addToFeatureFlagAllowlist(
            datedIrsProxy.getMarketEnabledFeatureFlagId(marketIdAave, maturityTimestampAave), mockCoreProxy
        );
        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));

        vm.stopPrank();

        aaveLendingPool.setAPY(wrap(0.02e18));
        aaveLendingPool.setStartTime(Time.blockTimestampTruncated());
    }

    function setConfigs_Glp_market() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({ marketId: marketIdGlp, quoteToken: address(mockGlpToken), marketType: "linear" });
        datedIrsProxy.setMarketConfiguration(
            marketIdGlp,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketIdGlp, maturityTimestampGlp), // 7 days
                markPriceBand: ud60x18(0.045e18), // 4.5%
                takerPositionsPerAccountLimit: 100,
                positionSizeUpperLimit: 1e27, // 1B
                positionSizeLowerLimit: 0,
                openInterestUpperLimit: 1e27 // 1B
             })
        );
        datedIrsProxy.setRateOracleConfiguration(
            marketIdGlp,
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

        DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
            maturityTimestamp: maturityTimestampGlp,
            maxLiquidityPerTick: type(uint128).max,
            tickSpacing: 60,
            marketId: marketIdGlp
        });

        DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
            priceImpactPhi: ud60x18(0.0001e18), // vol / volume = 0.01
            spread: ud60x18(0.01e18), // 1%
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
        observedTicks[0] = initTickGlp;
        observedTicks[1] = initTickGlp;
        vammProxy.createVamm({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTickGlp),
            times: times,
            observedTicks: observedTicks,
            config: immutableConfig,
            mutableConfig: mutableConfig
        });
        vammProxy.increaseObservationCardinalityNext(marketIdGlp, maturityTimestampGlp, 16);

        // FEATURE FLAGS
        datedIrsProxy.addToFeatureFlagAllowlist(
            datedIrsProxy.getMarketEnabledFeatureFlagId(marketIdGlp, maturityTimestampGlp), mockCoreProxy
        );
        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));

        vm.stopPrank();

        mockGlpRewardRouter.setAPY(wrap(0.1e18));
        mockGlpRewardRouter.setStartTime(Time.blockTimestampTruncated());
    }

    function test_scenario_F() public {
        setConfigs_Aave_market();
        setConfigs_Glp_market();
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

        int24 currentTick = vammProxy.getVammTick(marketIdAave, maturityTimestampAave);
        assertEq(currentTick, -16_096, "current tick");
        currentTick = vammProxy.getVammTick(marketIdGlp, maturityTimestampGlp);
        assertEq(currentTick, -23_027, "current tick");

        // t = 0: account 1 (LP) Aave
        executeDatedIrsMakerOrder({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // t = 0: account 1 (LP) GLP
        executeDatedIrsMakerOrder({
            marketId: marketIdGlp,
            maturityTimestamp: maturityTimestampGlp,
            accountId: 1,
            baseAmount: 1000 * 1e18,
            tickLower: -27_120, // 15%
            tickUpper: -16_140 // 5%
         });

        // check account 1 Aave
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3_523_858_284,
                expectedUnfilledBaseShort: 6_476_141_715,
                expectedUnfilledQuoteLong: 219_470_934,
                expectedUnfilledQuoteShort: 232_071_370
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        // check account 1 Glp
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 1, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 310_446_070_449_190_803_793,
                expectedUnfilledBaseShort: 689_553_929_550_809_196_206,
                expectedUnfilledQuoteLong: 41_198_760_337_346_016_142,
                expectedUnfilledQuoteShort: 41_972_657_502_152_943_674
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        // advance time (t = 0.25)
        vm.warp(start + 86_400 * 365 / 4);
        assertEq(1.005e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdAave)), "aave li 1/4");
        assertEq(0.025e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdGlp)), "glp li 1/4");

        // t = 0.25: account 2 (FT) Aave
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketIdAave,
                maturityTimestamp: maturityTimestampAave,
                accountId: 2,
                baseAmount: -1000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(45_102_186), "executedQuote");
                assertEq(annualizedNotional, -753_750_000, "annualizedNotional");
            }
        }

        // t = 0.25: account 3 (VT) Aave
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketIdAave,
                maturityTimestamp: maturityTimestampAave,
                accountId: 3,
                baseAmount: 2000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 2000 * 1e6, "executedBase");
                assertAlmostEq(executedQuote, int256(-106_736_826), 1e6, "executedQuote");
                assertEq(annualizedNotional, 1_507_500_000, "annualizedNotional");
            }
        }

        // t = 0.25: account 3 (FT) GLP
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketIdGlp,
                maturityTimestamp: maturityTimestampGlp,
                accountId: 3,
                baseAmount: -200 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, -200 * 1e18, "executedBase");
                assertEq(executedQuote, int256(15_869_560_501_219_547_400), "executedQuote");
                assertEq(annualizedNotional, -50e18, "annualizedNotional");
            }
        }

        // t = 0.25: account 2 (VT) GLP
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketIdGlp,
                maturityTimestamp: maturityTimestampGlp,
                accountId: 2,
                baseAmount: 400 * 1e18
            });

            // check outputs
            {
                assertEq(executedBase, 400 * 1e18, "executedBase");
                assertAlmostEq(executedQuote, int256(-44_576_739_076_981_875_600), 1e6, "executedQuote");
                assertEq(annualizedNotional, 100e18, "annualizedNotional");
            }
        }

        // check account 1 Aave
        {
            PositionInfo memory positionAave =
                PositionInfo({ accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionAave,
                expectedUnfilledBaseLong: 2_523_411_734,
                expectedUnfilledBaseShort: 7_476_588_265,
                expectedUnfilledQuoteLong: 164_937_727,
                expectedUnfilledQuoteShort: 282_829_596
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionAave,
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 61_634_640,
                expectedAccruedInterest: 0
            });
        }

        // check account 2 Aave
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 45_102_186,
                expectedAccruedInterest: 0
            });
        }

        // check account 3 Aave
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_000_000_000,
                expectedQuoteBalance: -106_736_826,
                expectedAccruedInterest: 0
            });
        }

        // check account 1 Glp
        {
            PositionInfo memory positionGlp =
                PositionInfo({ accountId: 1, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionGlp,
                expectedUnfilledBaseLong: 110_380_184_483_112_673_149,
                expectedUnfilledBaseShort: 889_619_815_516_887_326_850,
                expectedUnfilledQuoteLong: 16_482_429_557_428_148_354,
                expectedUnfilledQuoteShort: 62_687_670_562_749_248_678
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionGlp,
                expectedBaseBalance: -199_999_999_999_999_999_999,
                expectedQuoteBalance: 28_707_178_575_762_328_200,
                expectedAccruedInterest: 0
            });
        }

        // check account 2 Glp
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 2, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 400_000_000_000_000_000_000,
                expectedQuoteBalance: -44_576_739_076_981_875_600,
                expectedAccruedInterest: 0
            });
        }

        // check account 3 Glp
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -200_000_000_000_000_000_000,
                expectedQuoteBalance: 15_869_560_501_219_547_400,
                expectedAccruedInterest: 0
            });
        }

        invariantCheck(marketIdGlp, maturityTimestampGlp);
        invariantCheck(marketIdAave, maturityTimestampAave);

        // advance time (t = 0.375 or 3/8)
        vm.warp(start + 86_400 * 365 * 3 / 8);
        assertEq(1.0075e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdAave)), "aave li 3/8");
        assertEq(0.0375e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdGlp)), "glp li 3/8");

        // t = 0.375: account 3 (close unfilled order)
        closeAllUnfilledOrders({ marketId: marketIdAave, accountId: 1 });

        closeAllUnfilledOrders({ marketId: marketIdGlp, accountId: 1 });

        // check account 1 Aave
        {
            PositionInfo memory positionAave =
                PositionInfo({ accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });
            checkZeroUnfilledBalances({ datedIrsProxy: datedIrsProxy, positionInfo: positionAave });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionAave,
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 61_634_640,
                expectedAccruedInterest: 5_204_330
            });
        }

        // check account 2 Aave
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 45_102_186,
                expectedAccruedInterest: 3_137_773
            });
        }

        // check account 3 Aave
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2_000_000_000,
                expectedQuoteBalance: -106_736_826,
                expectedAccruedInterest: -8_342_103
            });
        }

        // check account 1 Glp
        {
            PositionInfo memory positionGlp =
                PositionInfo({ accountId: 1, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });
            checkZeroUnfilledBalances({ datedIrsProxy: datedIrsProxy, positionInfo: positionGlp });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionGlp,
                expectedBaseBalance: -199_999_999_999_999_999_999,
                expectedQuoteBalance: 28_707_178_575_762_328_200,
                expectedAccruedInterest: 1_088_397_321_970_291_024
            });
        }

        // check account 2 Glp
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 2, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 400_000_000_000_000_000_000,
                expectedQuoteBalance: -44_576_739_076_981_875_600,
                expectedAccruedInterest: -572_092_384_622_734_450
            });
        }

        // check account 3 Glp
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -200_000_000_000_000_000_000,
                expectedQuoteBalance: 15_869_560_501_219_547_400,
                expectedAccruedInterest: -516_304_937_347_556_575
            });
        }

        invariantCheck(marketIdGlp, maturityTimestampGlp);
        invariantCheck(marketIdAave, maturityTimestampAave);

        // advance time (t = 0.5)
        vm.warp(start + 86_400 * 365 / 2);
        assertEq(1.01e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdAave)), "aave li 1/2");
        assertEq(0.05e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdGlp)), "glp li 1/2");

        // ///////////////// SETTLE GLP /////////////////

        int256[] memory settlementCashflowsGlp = new int256[](3);

        // settle account 1
        settlementCashflowsGlp[0] =
            settle({ marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp, accountId: 1 });
        assertEq(settlementCashflowsGlp[0], 2_176_794_643_940_582_051, "settlement cashflow 1");

        // settle account 2
        settlementCashflowsGlp[1] =
            settle({ marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp, accountId: 2 });
        assertEq(settlementCashflowsGlp[1], -1_144_184_769_245_468_900, "settlement cashflow 2");

        // settle account 3
        settlementCashflowsGlp[2] =
            settle({ marketId: marketIdGlp, maturityTimestamp: maturityTimestampGlp, accountId: 3 });
        assertEq(settlementCashflowsGlp[2], -1_032_609_874_695_113_150, "settlement cashflow 3");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflowsGlp.length; i++) {
                netSettlementCashflow += settlementCashflowsGlp[i];
            }

            assertAlmostEq(netSettlementCashflow, int256(0), 3, "net settlement cashflow");
        }

        invariantCheck(marketIdGlp, maturityTimestampGlp);
        invariantCheck(marketIdAave, maturityTimestampAave);

        vm.warp(start + 86_400 * 365 * 7 / 8);

        invariantCheck(marketIdAave, maturityTimestampAave);

        vm.warp(start + 86_400 * 365);
        assertEq(1.02e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketIdAave)), "aave li 4/4");
        assertEq(
            0.05e18, unwrap(datedIrsProxy.getRateIndexMaturity(marketIdGlp, maturityTimestampGlp)), "glp li maturity"
        );

        ///////////////// SETTLE AAVE /////////////////

        int256[] memory settlementCashflowsAave = new int256[](3);

        // settle account 1
        settlementCashflowsAave[0] =
            settle({ marketId: marketIdAave, maturityTimestamp: maturityTimestampAave, accountId: 1 });
        assertEq(settlementCashflowsAave[0], 31_225_979, "settlement cashflow 1");

        // settle account 2
        settlementCashflowsAave[1] =
            settle({ marketId: marketIdAave, maturityTimestamp: maturityTimestampAave, accountId: 2 });
        assertEq(settlementCashflowsAave[1], 18_826_640, "settlement cashflow 2");

        // settle account 3
        settlementCashflowsAave[2] =
            settle({ marketId: marketIdAave, maturityTimestamp: maturityTimestampAave, accountId: 3 });
        assertEq(settlementCashflowsAave[2], -50_052_620, "settlement cashflow 3");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflowsAave.length; i++) {
                netSettlementCashflow += settlementCashflowsAave[i];
            }

            assertAlmostEq(netSettlementCashflow, int256(0), 3, "net settlement cashflow");
        }

        invariantCheck(marketIdAave, maturityTimestampAave);
    }
}
