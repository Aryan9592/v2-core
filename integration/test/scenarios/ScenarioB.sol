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
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { Market } from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";

import { DatedIrsVamm } from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { VammTicks } from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";

import { ud, wrap, unwrap } from "@prb/math/UD60x18.sol";

contract ScenarioB is ScenarioSetup, AssertionHelpers, Actions, Checks {
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
                markPriceBand: ud(0.045e18), // 1%
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

        datedIrsProxy.setPhi({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            phi: ud(0.0001e18) // vol / volume = 0.01
         });

        datedIrsProxy.setBeta({ marketId: marketId, maturityTimestamp: maturityTimestamp, beta: ud(0.5e18) });

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

    function test_scenario_B() public {
        setConfigs();
        uint256 start = block.timestamp;

        // LP
        {
            vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

            // action
            executeDatedIrsMakerOrder({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 1,
                baseAmount: 10_000 * 1e6,
                tickLower: -19_500, // 7%
                tickUpper: -11_040 // 3%
             });

            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp });

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3_523_858_284,
                expectedUnfilledBaseShort: 6_476_141_715,
                expectedUnfilledQuoteLong: 219_470_934, // higher than case A without spread & slippage
                expectedUnfilledQuoteShort: 232_071_370 // lower than case A without spread & slippage
             });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        vm.warp(start + 86_400 * 365 / 2);
        assertEq(1.01e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li 1/2");

        // short FT - account 2
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: -1000 * 1e6
            });

            // executed amounts checks
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase1");
                assertAlmostEq(executedQuote, int256(45_326_575), 1e6, "executedQuote1");
                assertEq(annualizedNotional, -505_000_000, "annualizedNotional1");
            }
        }

        // long VT - account 3
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 3,
                baseAmount: 2000 * 1e6
            });

            // executed amounts checks
            {
                assertEq(executedBase, 2000 * 1e6, "executedBase2");
                assertAlmostEq(executedQuote, int256(-107_293_150), 1e6, "executedQuote2");
                assertEq(annualizedNotional, 1_010_000_000, "annualizedNotional2");
            }
        }

        // long VT - account 4
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 4,
                baseAmount: 1000 * 1e6
            });

            // executed amounts checks
            {
                assertEq(executedBase, 1000 * 1e6, "executedBase3");
                assertAlmostEq(executedQuote, int256(-61_050_264), 1e6, "executedQuote3");
                assertEq(annualizedNotional, 505_000_000, "annualizedNotional3");
            }
        }

        // short FT - account 4
        {
            // action
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) =
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 4,
                baseAmount: -1000 * 1e6
            });

            // executed amounts checks
            {
                assertEq(executedBase, -1000 * 1e6, "executedBase4");
                assertAlmostEq(executedQuote, int256(54_998_289), 1e6, "executedQuote4");
                assertEq(annualizedNotional, -505_000_000, "annualizedNotional4");
            }
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 2_523_411_734,
                expectedUnfilledBaseShort: 7_476_588_265,
                expectedUnfilledQuoteLong: 165_758_312,
                expectedUnfilledQuoteShort: 284_236_708
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 68_001_278,
                expectedAccruedInterest: 0
            });
        }

        // check account 2
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1_000_000_000,
                expectedQuoteBalance: 45_326_575,
                expectedAccruedInterest: 0
            });
        }

        // check account 3
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 2_000_000_000,
                expectedQuoteBalance: -107_267_854,
                expectedAccruedInterest: 0
            });
        }

        // check account 4
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: 0,
                expectedQuoteBalance: -6_060_000,
                expectedAccruedInterest: 0
            });
        }

        invariantCheck();

        // 3/4 of time till maturity
        vm.warp(start + 86_400 * 365 * 3 / 4);
        assertEq(1.015e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li 3/4");

        //////////// 1/4 UNTIL MATURITY ////////////

        // check balances LP
        {
            // unfilled (shouldn't have chganged since the mint)
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedUnfilledBaseLong: 2_523_411_734,
                expectedUnfilledBaseShort: 7_476_588_265,
                expectedUnfilledQuoteLong: 166_578_898,
                expectedUnfilledQuoteShort: 285_643_820
            });

            // filled
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({ accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp }),
                expectedBaseBalance: -1000e6,
                expectedQuoteBalance: 68_001_278,
                expectedAccruedInterest: 12_000_319
            });
        }

        // check balances FT
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp });
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1000e6,
                expectedQuoteBalance: 45_326_575,
                expectedAccruedInterest: 6_331_643
            });
        }

        // check balances VT
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp });
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2000e6,
                expectedQuoteBalance: -107_267_854,
                expectedAccruedInterest: -16_816_963
            });
        }

        // check balances Account 4
        {
            PositionInfo memory positionInfo =
                PositionInfo({ accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp });
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 0,
                expectedQuoteBalance: -6_060_000,
                expectedAccruedInterest: -1_515_000
            });
        }

        invariantCheck();

        vm.warp(start + 86_400 * 365 - 1);

        invariantCheck();

        vm.warp(start + 86_400 * 365);

        int256[] memory settlementCashflows = new int256[](4);

        //////////// AFTER MATURITY ////////////

        // settle account 1
        settlementCashflows[0] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 1 });
        {
            assertEq(settlementCashflows[0], 24_000_637, "settlementCashflowInQuote_1");

            // check settlement twice does not work
            vm.expectRevert(SetUtil.ValueNotInSet.selector);
            settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 1 });
            // check maturity index was cached
            assertEq(1_020_000_000_000_000_000, unwrap(datedIrsProxy.getRateIndexMaturity(marketId, maturityTimestamp)));
        }

        // settle account 2
        settlementCashflows[1] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 2 });
        assertEq(settlementCashflows[1], 12_663_287, "settlementCashflowInQuote_2");

        // settle account 3
        settlementCashflows[2] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 3 });
        assertEq(settlementCashflows[2], -33_633_926, "settlementCashflowInQuote_3");

        // settle account 4
        settlementCashflows[3] = settle({ marketId: marketId, maturityTimestamp: maturityTimestamp, accountId: 4 });

        assertEq(settlementCashflows[3], -3_030_000, "settlementCashflowInQuote_4");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflows.length; i++) {
                netSettlementCashflow += settlementCashflows[i];
            }
            assertAlmostEq(netSettlementCashflow, int256(0), 3, "net settlement cashflow");
        }

        invariantCheck();
    }
}
