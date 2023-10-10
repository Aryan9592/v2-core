pragma solidity >=0.8.19;

import {CollateralConfiguration} from "@voltz-protocol/core/src/storage/CollateralConfiguration.sol";
import {SafeCastI256, SafeCastU256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {ScenarioSetup} from "./utils/ScenarioSetup.sol";
import {AssertionHelpers} from "./utils/AssertionHelpers.sol";
import {Constants} from "./utils/Constants.sol";
import {PoolConfiguration} from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import {Market} from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";
import {IAccountModule} from "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IRateOracle} from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import {VammConfiguration} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammConfiguration.sol";
import {DatedIrsVamm} from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import {DatedIrsProxy} from "../../src/proxies/DatedIrs.sol";
import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {Actions} from "./utils/Actions.sol";
import {Checks} from "./utils/Checks.sol";
import {Time} from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import {VammProxy} from "../../src/proxies/Vamm.sol";
import {VammTicks} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";
import {VammHelpers} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammHelpers.sol";
import {Utils} from "../../src/utils/Utils.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import { ud60x18, div, SD59x18, UD60x18, convert, unwrap, wrap } from "@prb/math/UD60x18.sol";

contract ScenarioC is ScenarioSetup, AssertionHelpers, Actions, Checks {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    uint128 public productId;
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

    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal pure override returns(uint32) {
        return 7 * 86400;
    }

    function invariantCheck() internal {
        uint128[] memory accountIds = new uint128[](5);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;
        accountIds[3] = 4;
        accountIds[4] = 5;

        checkTotalFilledBalances(
            datedIrsProxy,
            marketId,
            maturityTimestamp,
            accountIds
        );
    }

    function setUp() public {
        super.datedIrsSetup();
        marketId = 1;
        maturityTimestamp = uint32(block.timestamp) + 365 * 86400; // in 1 year
        initTick = -16096; // 5%
    }

    function setConfigs() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({
            marketId: marketId,
            quoteToken: address(mockUsdc),
            marketType: "compounding"
        });

        datedIrsProxy.setMarketConfiguration(
            marketId,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketId, maturityTimestamp), // 7 days
                markPriceBand: ud60x18(0.045e18), // 4.5%
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

        vammProxy.setPoolConfiguration(PoolConfiguration.Data({
            marketManagerAddress: address(datedIrsProxy),
            makerPositionsPerAccountLimit: 1e27 // 1B
        }));

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
            inactiveWindowBeforeMaturity: 86400
        });

        // ensure the current time > 7 days
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86400 * 8);
        times[1] = uint32(block.timestamp - 86400 * 4);
        int24[] memory observedTicks = new int24[](2);
        observedTicks[0] = -16096;
        observedTicks[1] = -16096;
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
            keccak256(abi.encode(Constants._MARKET_ENABLED_FEATURE_FLAG, marketId)), mockCoreProxy
        );

        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));

        vm.stopPrank();
        
        aaveLendingPool.setAPY(wrap(0.02e18));
        aaveLendingPool.setStartTime(Time.blockTimestampTruncated());
    }

    function test_scenario_C() public {
        setConfigs();
        uint256 start = block.timestamp;

        vm.mockCall(
            mockUsdc,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(6)
        );

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16096, "current tick");

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -17940, // 6%
            tickUpper: -13920 // 4% 
        });

        // check account 1
        {   
            PositionInfo memory positionInfo = PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp});

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3523858284,
                expectedUnfilledBaseShort: 6476141715,
                expectedUnfilledQuoteLong: 208899359,
                expectedUnfilledQuoteShort: 251499795
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        // check account 2
        {   
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 4338438696,
                expectedUnfilledBaseShort: 5661561303,
                expectedUnfilledQuoteLong: 237891466,
                expectedUnfilledQuoteShort: 253917588
            });
            checkZeroFilledBalances(
                datedIrsProxy, 
                PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp})
            );
        }

        // advance time (t = 0.25)
        vm.warp(start + 86400 * 365 / 4);

        // t = 0.25: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.25: account 3 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 3,
            baseAmount: 10_000 * 1e6,
            tickLower: -22020, // 9%
            tickUpper: -19500 // 7% 
        });

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 7047716568,
                expectedUnfilledBaseShort: 12952283431,
                expectedUnfilledQuoteLong: 419887712,
                expectedUnfilledQuoteShort: 505514588
            });
            checkZeroFilledBalances(
                datedIrsProxy,
                PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp})
            );
        }

        // check account 3
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 9999999999,
                expectedUnfilledBaseShort: 0,
                expectedUnfilledQuoteLong: 801154597,
                expectedUnfilledQuoteShort: 0
            });
            checkZeroFilledBalances(
                datedIrsProxy, 
                PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp})
            );
        }

        // advance time
        vm.warp(start + 86400 * 365 / 2);

        // t = 0.5: account 4 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 4,
                    baseAmount: -18_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -18_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(745587342), "executedQuote");
                assertEq(annualizedNotional, -9090000000, "annualizedNotional");
            }            
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -11253, "current tick");

        // t = 0.5: account 5 (VT)
        {   
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 5,
                    baseAmount: 38_000 * 1e6
                }); 

            // check outputs
            {
                assertEq(executedBase, 38_000 * 1e6, "executedBase");
                assertAlmostEq(executedQuote, int256(-2088697274), 1e6, "executedQuote");
                assertEq(annualizedNotional, 19190000000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -21652, "current tick");

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 19999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 930006292
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -7047716566, 
                expectedQuoteBalance: 421976705,
                expectedAccruedInterest: 0
            });
        } 

        // check account 4
        {
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -18000000000, 
                expectedQuoteBalance: 745587342,
                expectedAccruedInterest: 0
            });
        } 

        invariantCheck();

        vm.warp(start + 86400 * 365 * 3 / 4);
        // liquidity index 1.015

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 19999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 934610284
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -7047716566, 
                expectedQuoteBalance: 421976705,
                expectedAccruedInterest: 70255593
            });
        } 

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 9999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 499186190
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -4338438695, 
                expectedQuoteBalance: 240270381,
                expectedAccruedInterest: 38375401
            });
        } 

        // check account 3
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 1382936724,
                expectedUnfilledBaseShort: 8617063275,
                expectedUnfilledQuoteLong: 124608127,
                expectedUnfilledQuoteShort: 684518157
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -8613844737, 
                expectedQuoteBalance: 680862844,
                expectedAccruedInterest: 127146487
            });
        } 

        // check account 4
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);
            
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -18000000000, 
                expectedQuoteBalance: 745587342,
                expectedAccruedInterest: 96396835
            });
        } 

        // check account 5
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 5, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 38000000000, 
                expectedQuoteBalance: -2088697274,
                expectedAccruedInterest: -332174318
            });
        } 

        invariantCheck();

        vm.warp(start + 86400 * 365 * 7 / 8);

        invariantCheck();

        vm.warp(start + 86400 * 365);

        int256[] memory settlementCashflows = new int256[](5);

        // settle account 1
        settlementCashflows[0] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1
        });
        assertEq(settlementCashflows[0], 140511185, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2
        });
        assertEq(settlementCashflows[1], 76750804, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 3
        });
        assertEq(settlementCashflows[2], 254292974, "settlement cashflow 3");

        // settle account 4
        settlementCashflows[3] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 4
        });
        assertEq(settlementCashflows[3], 192793670, "settlement cashflow 4");

        // settle account 5
        settlementCashflows[4] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 5
        });
        assertEq(settlementCashflows[4], -664348635, "settlement cashflow 5");

        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflows.length; i++) {
                netSettlementCashflow += settlementCashflows[i];
            }

            assertAlmostEq(
                netSettlementCashflow,
                int(0),
                5,
                "net settlement cashflow"
            );
        }

        invariantCheck();
    }
}