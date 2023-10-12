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

contract ScenarioG is ScenarioSetup, AssertionHelpers, Actions, Checks {
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
        uint128[] memory accountIds = new uint128[](3);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;

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
            priceImpactPhi: ud60x18(0.0001e18), // vol / volume = 0.01
            spread: ud60x18(0.003e18), // 0.3%
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

        // t = 0: account 3 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: -1_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(44877797), "executedQuote");
                assertEq(annualizedNotional, -1000000000, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 4523743141,
                expectedUnfilledBaseShort: 5476256858,
                expectedUnfilledQuoteLong: 270343108,
                expectedUnfilledQuoteShort: 187198505
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 999999999, 
                expectedQuoteBalance: -44877796,
                expectedAccruedInterest: 0
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1000000000, 
                expectedQuoteBalance: 44877797,
                expectedAccruedInterest: 0
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15227, "current tick");
        assertEq(1e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.125)
        vm.warp(start + 86400 * 365 / 8);

        // t = 0.125: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.125: account 3 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: -1_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(41992290), "executedQuote");
                assertEq(annualizedNotional, -877187500, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 5022797400,
                expectedUnfilledBaseShort: 4977202599,
                expectedUnfilledQuoteLong: 294978310,
                expectedUnfilledQuoteShort: 166708968
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1499999999, 
                expectedQuoteBalance: -65873941,
                expectedAccruedInterest: -3109724
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 5022797400,
                expectedUnfilledBaseShort: 4977202599,
                expectedUnfilledQuoteLong: 294978310,
                expectedUnfilledQuoteShort: 166708968
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 499999999, 
                expectedQuoteBalance: -20996144,
                expectedAccruedInterest: 0
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2000000000, 
                expectedQuoteBalance: 86870087,
                expectedAccruedInterest: 3109724
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14807, "current tick");
        assertEq(1.0025e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 2 / 8 ///////////////////////////

        // advance time (t = 0.25)
        vm.warp(start + 86400 * 365 / 4);

        invariantCheck();

        // t = 0.25: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
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
                assertEq(executedQuote, int256(-23748262), "executedQuote");
                assertEq(annualizedNotional, 376875000, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 9712945257,
                expectedUnfilledBaseShort: 10287054742,
                expectedUnfilledQuoteLong: 575627038,
                expectedUnfilledQuoteShort: 348044322
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1166666666, 
                expectedQuoteBalance: -50041767,
                expectedAccruedInterest: -7593967
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 4856472628,
                expectedUnfilledBaseShort: 5143527371,
                expectedUnfilledQuoteLong: 287813519,
                expectedUnfilledQuoteShort: 174022161
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 333333333, 
                expectedQuoteBalance: -13080057,
                expectedAccruedInterest: -1374528
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -1500000000, 
                expectedQuoteBalance: 63121825,
                expectedAccruedInterest: 8968484
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14946, "current tick");
        assertEq(1.005e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 3 / 8 ///////////////////////////

        // advance time (t = 0.375)
        vm.warp(start + 86400 * 365 * 3 / 8);

        invariantCheck();

        // t = 0.375: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.375: account 3 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: -1_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(41415487), "executedQuote");
                assertEq(annualizedNotional, -629687500, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 10213993446,
                expectedUnfilledBaseShort: 9786006552,
                expectedUnfilledQuoteLong: 600839788,
                expectedUnfilledQuoteShort: 328158098
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1666666665, 
                expectedQuoteBalance: -70749509,
                expectedAccruedInterest: -10932510
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 10213993446,
                expectedUnfilledBaseShort: 9786006552,
                expectedUnfilledQuoteLong: 600839788,
                expectedUnfilledQuoteShort: 328158098
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 833333332, 
                expectedQuoteBalance: -33787800,
                expectedAccruedInterest: -2176182
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -2500000000, 
                expectedQuoteBalance: 104537312,
                expectedAccruedInterest: 13108712
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -14737, "current tick");
        assertEq(1.0075e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 4 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86400 * 365 / 2);

        invariantCheck();

        // t = 0.5: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.5: account 3 (VT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: 5_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, 5_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-245122987), "executedQuote");
                assertEq(annualizedNotional, 2525000000, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 12319662811,
                expectedUnfilledBaseShort: 17680337188,
                expectedUnfilledQuoteLong: 756352268,
                expectedUnfilledQuoteShort: 622414327
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1333333334, 
                expectedQuoteBalance: 76324283,
                expectedAccruedInterest: -15609532
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 8213108541,
                expectedUnfilledBaseShort: 11786891458,
                expectedUnfilledQuoteLong: 504234845,
                expectedUnfilledQuoteShort: 414942884
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1166666666, 
                expectedQuoteBalance: 64261394,
                expectedAccruedInterest: -4316323 
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2500000000, 
                expectedQuoteBalance: -140585675,
                expectedAccruedInterest: 19925876
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15585, "current tick");
        assertEq(1.01e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 5 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86400 * 365 * 5 / 8);

        invariantCheck();

        // t = 0.625: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
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
                assertEq(executedQuote, int256(-25658051), "executedQuote");
                assertEq(annualizedNotional, 189843750, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 12070645555,
                expectedUnfilledBaseShort: 17929354444,
                expectedUnfilledQuoteLong: 745445338,
                expectedUnfilledQuoteShort: 635221265
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1583333334, 
                expectedQuoteBalance: 89153308,
                expectedAccruedInterest: -9402350
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 12070645555,
                expectedUnfilledBaseShort: 17929354444,
                expectedUnfilledQuoteLong: 745445338,
                expectedUnfilledQuoteShort: 635221265
            });
            
            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1416666665, 
                expectedQuoteBalance: 77090419,
                expectedAccruedInterest: 799683 
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 3000000000, 
                expectedQuoteBalance: -166243726,
                expectedAccruedInterest: 8602667
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15657, "current tick");
        assertEq(1.0125e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 6 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86400 * 365 * 6 / 8);

        invariantCheck();

        // t = 0.75: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.75: account 3 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: -1_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(45228421), "executedQuote");
                assertEq(annualizedNotional, -253750000, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 16666755894,
                expectedUnfilledBaseShort: 23333244105,
                expectedUnfilledQuoteLong: 1025764631,
                expectedUnfilledQuoteShort: 823156480
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1011904763, 
                expectedQuoteBalance: 63308497,
                expectedAccruedInterest: -2216499
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 12500066920,
                expectedUnfilledBaseShort: 17499933079,
                expectedUnfilledQuoteLong: 769323473,
                expectedUnfilledQuoteShort: 617367360
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -988095238, 
                expectedQuoteBalance: 57706811,
                expectedAccruedInterest: 6894321 
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: 2000000000, 
                expectedQuoteBalance: -121015305,
                expectedAccruedInterest: -4677798
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15533, "current tick");
        assertEq(1.015e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 7 / 8 ///////////////////////////

        // advance time
        vm.warp(start + 86400 * 365 * 7 / 8);

        invariantCheck();

        // t = 0.875: account 2 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3% 
        });

        // t = 0.875: account 3 (FT)
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: -5_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -5_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(218887799), "executedQuote");
                assertEq(annualizedNotional, -635937500, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 19163916715,
                expectedUnfilledBaseShort: 20836083283,
                expectedUnfilledQuoteLong: 1152859673,
                expectedUnfilledQuoteShort: 715860597
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1488095237, 
                expectedQuoteBalance: -46135403,
                expectedAccruedInterest: 3167301
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 19163916715,
                expectedUnfilledBaseShort: 20836083283,
                expectedUnfilledQuoteLong: 1152859673,
                expectedUnfilledQuoteShort: 715860597
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1511904761, 
                expectedQuoteBalance: -51737088,
                expectedAccruedInterest: 11637435 
            });
        }

        // check account 3
        {
            PositionInfo memory positionInfo = 
                 PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3000000000, 
                expectedQuoteBalance: 97872494,
                expectedAccruedInterest: -14804711
            });
        } 

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15001, "current tick");
        assertEq(1.0175e18, unwrap(datedIrsProxy.getRateIndexCurrent(marketId)), "li");

        /////////////////////////// 15 / 16 ///////////////////////////

        // advance time
        vm.warp(start + 86400 * 365 * 15 / 16);

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
                assertEq(executedQuote, int256(21239808), "executedQuote");
                assertEq(annualizedNotional, -31835937, "annualizedNotional");
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
                assertEq(executedQuote, int256(-24296058), "executedQuote");
                assertEq(annualizedNotional, 31835937, "annualizedNotional");
            }            
        }

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 19163916715,
                expectedUnfilledBaseShort: 20836083283,
                expectedUnfilledQuoteLong: 1154275963,
                expectedUnfilledQuoteShort: 716740033
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1488095237, 
                expectedQuoteBalance: -44607278,
                expectedAccruedInterest: 2143957
            });
        } 

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 19163916715,
                expectedUnfilledBaseShort: 20836083283,
                expectedUnfilledQuoteLong: 1154275963,
                expectedUnfilledQuoteShort: 716740033
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 1511904761, 
                expectedQuoteBalance: -50208963,
                expectedAccruedInterest: 10293749
            });
        } 

        // check account 3
        {
            PositionInfo memory positionInfo = 
                PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkZeroUnfilledBalances(datedIrsProxy, positionInfo);

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalance: -3000000000, 
                expectedQuoteBalance: 94816244,
                expectedAccruedInterest: -12437681
            });
        } 

        /////////////////////////// SETTLEMENT ///////////////////////////
        invariantCheck();

        vm.warp(start + 86400 * 365);

        int256[] memory settlementCashflows = new int256[](3);

        // settle account 1
        settlementCashflows[0] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1
        });
        assertEq(settlementCashflows[0], 1216111, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2
        });
        assertEq(settlementCashflows[1], 9045559, "settlement cashflow 2");

        // settle account 3
        settlementCashflows[2] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 3
        });
        assertEq(settlementCashflows[2], -10261665, "settlement cashflow 3");

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