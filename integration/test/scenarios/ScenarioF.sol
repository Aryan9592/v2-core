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

contract ScenarioF is ScenarioSetup, AssertionHelpers, Actions, Checks {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    uint128 public productId;
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

    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal pure override returns(uint32) {
        return 7 * 86400;
    }

    function invariantCheck(uint128 marketId, uint32 maturityTimestamp) internal {
        uint128[] memory accountIds = new uint128[](5);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;
        accountIds[3] = 4;
        accountIds[4] = 5;

        checkTotalFilledBalances(
            address(vammProxy),
            datedIrsProxy,
            marketId,
            maturityTimestamp,
            accountIds
        );
    }

    function setUp() public {
        super.datedIrsSetup();
        marketIdAave = 1;
        marketIdGlp = 2;
        maturityTimestampAave = uint32(block.timestamp) + 365 * 86400; // in 1 year
        maturityTimestampGlp = uint32(block.timestamp) + 365 * 86400 / 2; // in 1 year
        initTickAave = -16096; // 5%
        initTickGlp = -23027; // 10%
    }

    function setConfigs_Aave_market() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({
            marketId: marketIdAave,
            quoteToken: address(mockToken),
            marketType: "compounding"
        });
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

        vammProxy.setPoolConfiguration(PoolConfiguration.Data({
            marketManagerAddress: address(datedIrsProxy),
            makerPositionsPerAccountLimit: 1e27 // 1B
        }));

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
            minTickAllowed: TickMath.DEFAULT_MIN_TICK,
            maxTickAllowed: TickMath.DEFAULT_MAX_TICK
        });

        // ensure the current time > 7 days
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86400 * 8);
        times[1] = uint32(block.timestamp - 86400 * 4);
        int24[] memory observedTicks = new int24[](2);
        observedTicks[0] = -16096;
        observedTicks[1] = -16096;
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
            keccak256(abi.encode(Constants._MARKET_ENABLED_FEATURE_FLAG, marketIdAave)), mockCoreProxy
        );
        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));


        vm.stopPrank();
        
        aaveLendingPool.setAPY(wrap(0.02e18));
        aaveLendingPool.setStartTime(Time.blockTimestampTruncated());
    }

    function setConfigs_Glp_market() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({
            marketId: marketIdGlp,
            quoteToken: address(mockToken),
            marketType: "linear"
        });
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

        vammProxy.setPoolConfiguration(PoolConfiguration.Data({
            marketManagerAddress: address(datedIrsProxy),
            makerPositionsPerAccountLimit: 1e27 // 1B
        }));

        DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
            maturityTimestamp: maturityTimestampGlp,
            maxLiquidityPerTick: type(uint128).max,
            tickSpacing: 100,
            marketId: marketIdGlp
        });

        DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
            priceImpactPhi: ud60x18(0.0001e18), // vol / volume = 0.01
            spread: ud60x18(0.01e18), // 1%
            minSecondsBetweenOracleObservations: 10,
            minTickAllowed: TickMath.DEFAULT_MIN_TICK,
            maxTickAllowed: TickMath.DEFAULT_MAX_TICK
        });

        // ensure the current time > 7 days
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86400 * 8);
        times[1] = uint32(block.timestamp - 86400 * 4);
        int24[] memory observedTicks = new int24[](2);
        observedTicks[0] = initTickGlp;
        observedTicks[1] = initTickGlp;
        vammProxy.createVamm({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTickAave),
            times: times,
            observedTicks: observedTicks,
            config: immutableConfig,
            mutableConfig: mutableConfig
        });
        vammProxy.increaseObservationCardinalityNext(marketIdGlp, maturityTimestampGlp, 16);

        // FEATURE FLAGS
        datedIrsProxy.addToFeatureFlagAllowlist(
            keccak256(abi.encode(Constants._MARKET_ENABLED_FEATURE_FLAG, marketIdGlp)), mockCoreProxy
        );
        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));


        vm.stopPrank();
        
        mockGlpRewardRouter.setAPY(wrap(0.02e18));
        mockGlpRewardRouter.setStartTime(Time.blockTimestampTruncated());
    }

    function test_scenario_F() public {
        setConfigs_Aave_market();
        uint256 start = block.timestamp;

        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(6)
        );

        int24 currentTick = vammProxy.getVammTick(marketIdAave, maturityTimestampAave);
        assertEq(currentTick, -16096, "current tick");

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -17940, // 6%
            tickUpper: -13920 // 4% 
        });

        // check account 1
        {   
            PositionInfo memory positionInfo = PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave});

            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3523858284,
                expectedUnfilledBaseShort: 6476141715,
                expectedUnfilledQuoteLong: 208899359,
                expectedUnfilledQuoteShort: 251499795
            });

            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
        }

        // check account 2
        {   
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 4338438696,
                expectedUnfilledBaseShort: 5661561303,
                expectedUnfilledQuoteLong: 237891466,
                expectedUnfilledQuoteShort: 253917588
            });
            checkZeroPoolFilledBalances(
                address(vammProxy), 
                PositionInfo({accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave})
            );
        }

        // advance time (t = 0.25)
        vm.warp(start + 86400 * 365 / 4);

        // t = 0.25: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.25: account 3 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 3,
            baseAmount: 10_000 * 1e6,
            tickLower: -22020, // 9%
            tickUpper: -19500 // 7% 
        });

        // check account 1
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 7047716568,
                expectedUnfilledBaseShort: 12952283431,
                expectedUnfilledQuoteLong: 419887712,
                expectedUnfilledQuoteShort: 505514588
            });
            checkZeroPoolFilledBalances(
                address(vammProxy),
                PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave})
            );
        }

        // check account 3
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 9999999999,
                expectedUnfilledBaseShort: 0,
                expectedUnfilledQuoteLong: 801154597,
                expectedUnfilledQuoteShort: 0
            });
            checkZeroPoolFilledBalances(
                address(vammProxy), 
                PositionInfo({accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave})
            );
        }

        // advance time
        vm.warp(start + 86400 * 365 / 2);

        // t = 0.5: account 4 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketIdAave,
                    maturityTimestamp: maturityTimestampAave,
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

        currentTick = vammProxy.getVammTick(marketIdAave, maturityTimestampAave);
        assertEq(currentTick, -11253, "current tick");

        // t = 0.5: account 5 (VT)
        {   
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketIdAave,
                    maturityTimestamp: maturityTimestampAave,
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

        currentTick = vammProxy.getVammTick(marketIdAave, maturityTimestampAave);
        assertEq(currentTick, -21652, "current tick");

        // check account 1
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 19999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 930006292
            });

            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedBaseBalancePool: -7047716566, 
                expectedQuoteBalancePool: 421976705,
                expectedAccruedInterestPool: 0
            });
        } 

        // check account 4
        {
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 4, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedBaseBalancePool: -18000000000, 
                expectedQuoteBalancePool: 745587342,
                expectedAccruedInterestPool: 0
            });
        } 

        invariantCheck(marketIdAave, maturityTimestampAave);

        vm.warp(start + 86400 * 365 * 3 / 4);
        // liquidity index 1.015

        // check account 1
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 19999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 934610284
            });

            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedBaseBalancePool: -7047716566, 
                expectedQuoteBalancePool: 421976705,
                expectedAccruedInterestPool: 70255593
            });
        } 

        // check account 2
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 0,
                expectedUnfilledBaseShort: 9999999999,
                expectedUnfilledQuoteLong: 0,
                expectedUnfilledQuoteShort: 499186190
            });

            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedBaseBalancePool: -4338438695, 
                expectedQuoteBalancePool: 240270381,
                expectedAccruedInterestPool: 38375401
            });
        } 

        // check account 3
        {
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedUnfilledBaseLong: 1382936724,
                expectedUnfilledBaseShort: 8617063275,
                expectedUnfilledQuoteLong: 124608127,
                expectedUnfilledQuoteShort: 684518157
            });

            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 3, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave}),
                expectedBaseBalancePool: -8613844737, 
                expectedQuoteBalancePool: 680862844,
                expectedAccruedInterestPool: 127146487
            });
        } 

        // check account 4
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 4, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave});
            
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: -18000000000, 
                expectedQuoteBalancePool: 745587342,
                expectedAccruedInterestPool: 96396835
            });
        } 

        // check account 5
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 5, marketId: marketIdAave, maturityTimestamp: maturityTimestampAave});
            
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);

            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: 38000000000, 
                expectedQuoteBalancePool: -2088697274,
                expectedAccruedInterestPool: -332174318
            });
        } 

        invariantCheck(marketIdAave, maturityTimestampAave);

        vm.warp(start + 86400 * 365 * 7 / 8);

        invariantCheck(marketIdAave, maturityTimestampAave);

        vm.warp(start + 86400 * 365);

        int256[] memory settlementCashflows = new int256[](5);

        // settle account 1
        settlementCashflows[0] = settle({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 1
        });
        assertEq(settlementCashflows[0], 140511187, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 2
        });
        assertEq(settlementCashflows[1], 76750803, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 3
        });
        assertEq(settlementCashflows[2], 254292975, "settlement cashflow 3");

        // settle account 4
        settlementCashflows[3] = settle({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 4
        });
        assertEq(settlementCashflows[3], 192793669, "settlement cashflow 4");

        // settle account 5
        settlementCashflows[4] = settle({
            marketId: marketIdAave,
            maturityTimestamp: maturityTimestampAave,
            accountId: 5
        });
        assertEq(settlementCashflows[4], -664348636, "settlement cashflow 5");

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

        invariantCheck(marketIdAave, maturityTimestampAave);
    }
}