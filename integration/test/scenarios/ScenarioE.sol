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

contract ScenarioE is ScenarioSetup, AssertionHelpers, Actions, Checks {
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
        uint128[] memory accountIds = new uint128[](4);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;
        accountIds[3] = 4;

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
                markPriceBand: ud60x18(0.01e18), // 1%
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

        DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
            maturityTimestamp: maturityTimestamp,
            maxLiquidityPerTick: type(uint128).max,
            tickSpacing: 60,
            marketId: marketId
        });

        DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
            priceImpactPhi: ud60x18(0), // 1
            spread: ud60x18(0), // 0%
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

    function test_scenario_E() public {
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

        // t = 0: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -17_940, // 6%
            tickUpper: -13_920 // 4%
         });

        // check account 1
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3_523_858_284,
                expectedUnfilledBaseShort: 6_476_141_715,
                expectedUnfilledQuoteLong: 208_899_359,
                expectedUnfilledQuoteShort: 251_499_795
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 4_338_438_696,
                expectedUnfilledBaseShort: 5_661_561_303,
                expectedUnfilledQuoteLong: 237_891_466,
                expectedUnfilledQuoteShort: 253_917_588
            });
            checkZeroFilledBalances(
                datedIrsProxy, PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp })
            );
        }

        // advance time
        vm.warp(start + 86_400 * 365 / 2);

        // t = 0.5: account 3 (FT)
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
                assertEq(executedQuote, int256(49_810_161), "executedQuote");
                assertEq(annualizedNotional, -505_000_000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_820, "current tick");

        // t = 0.5: account 4 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 4,
                baseAmount: 2000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 2000 * 1e6, "executedBase");
                assertAlmostEq(executedQuote, int256(-101_151_411), 1e6, "executedQuote");
                assertEq(annualizedNotional, 1_010_000_000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16_377, "current tick");

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 3_209_720_189,
                expectedUnfilledBaseShort: 6_790_279_810,
                expectedUnfilledQuoteLong: 194_898_615,
                expectedUnfilledQuoteShort: 270_104_530
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -313_711_024,
                expectedQuoteBalance: 16_067_554,
                expectedAccruedInterest: 0
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 3_651_215_442,
                expectedUnfilledBaseShort: 6_348_784_557,
                expectedUnfilledQuoteLong: 205_071_714,
                expectedUnfilledQuoteShort: 291_655_430
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -686_288_975,
                expectedQuoteBalance: 35_150_137,
                expectedAccruedInterest: 0
            });
        }

        // check account 3
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 49_810_161,
                expectedAccruedInterest: 0
            });
        }

        // check account 4
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 2_000_000_000,
                expectedQuoteBalance: -101_027_853,
                expectedAccruedInterest: 0
            });
        }

        // t = 0.5: account 1 (LP - unwind)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: -10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 0,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 0
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -313_711_024,
                expectedQuoteBalance: 16_067_554,
                expectedAccruedInterest: 0
            });
        }

        // t = 0.5: account 3 (FT)
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
                assertEq(executedQuote, int256(50_893_574), "executedQuote");
                assertEq(annualizedNotional, -505_000_000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15_970, "current tick");

        // t = 0.5: account 4 (VT)
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 4,
                baseAmount: 2000 * 1e6
            });

            // check outputs
            {
                assertEq(executedBase, 2000 * 1e6, "executedBase");
                assertAlmostEq(executedQuote, int256(-103_926_735), 1e6, "executedQuote");
                assertEq(annualizedNotional, 1_010_000_000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16_793, "current tick");

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 0,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 0
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -313_711_024,
                expectedQuoteBalance: 16_067_554,
                expectedAccruedInterest: 0
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 2_651_395_232,
                expectedUnfilledBaseShort: 7_348_604_767,
                expectedUnfilledQuoteLong: 152_046_227,
                expectedUnfilledQuoteShort: 344_680_918
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_686_288_975,
                expectedQuoteBalance: 88_183_298,
                expectedAccruedInterest: 0
            });
        }

        // check account 3
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -2000 * 1e6,
                expectedQuoteBalance: 100_703_735,
                expectedAccruedInterest: 0
            });
        }

        // check account 4
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 4000 * 1e6,
                expectedQuoteBalance: -204_954_588,
                expectedAccruedInterest: 0
            });
        }

        invariantCheck();

        vm.warp(start + 86_400 * 365 * 3 / 4);
        // liquidity index 1.015

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 0,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 0
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -313_711_024,
                expectedQuoteBalance: 16_067_554,
                expectedAccruedInterest: 2_448_333
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 2_651_395_232,
                expectedUnfilledBaseShort: 7_348_604_767,
                expectedUnfilledQuoteLong: 152_798_931,
                expectedUnfilledQuoteShort: 346_387_259
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_686_288_975,
                expectedQuoteBalance: 88_183_298,
                expectedAccruedInterest: 13_614_379
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2000 * 1e6,
                expectedQuoteBalance: 100_703_735,
                expectedAccruedInterest: 15_175_933
            });
        }

        // check account 4
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 4000 * 1e6,
                expectedQuoteBalance: -204_954_588,
                expectedAccruedInterest: -31_238_647
            });
        }

        invariantCheck();

        vm.warp(start + 86_400 * 365 * 7 / 8);

        invariantCheck();

        vm.warp(start + 86_400 * 365);

        int256[] memory settlementCashflows = new int256[](5);

        // settle account 1
        settlementCashflows[0] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 1 });

        assertEq(settlementCashflows[0], 4_896_666, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 2 });
        assertEq(settlementCashflows[1], 27_228_760, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 3 });
        assertEq(settlementCashflows[2], 30_351_868, "settlement cashflow 3");

        // settle account 4
        settlementCashflows[3] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 4 });
        assertEq(settlementCashflows[3], -62_477_295, "settlement cashflow 4");

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
