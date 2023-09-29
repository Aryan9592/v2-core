pragma solidity >=0.8.19;

// import "forge-std/console2.sol";

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

import "forge-std/console2.sol";

contract ScenarioA is ScenarioSetup, AssertionHelpers, Actions, Checks {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    address internal user1;
    address internal user2;

    uint128 productId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int24 initTick;

    function getDatedIrsProxy() internal view override returns (DatedIrsProxy) {
        return datedIrsProxy;
    }

    function getCoreProxyAddress() internal view override returns (address) {
        return mockCoreProxy;
    }

    function getVammProxy() internal view override returns (VammProxy) {
        return vammProxy;
    }
    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view override returns(uint32) {
        return 7 * 86400;
    }

    function invariantCheck() internal {
        uint128[] memory accountIds = new uint128[](4);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;
        accountIds[3] = 4;

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
        marketId = 1;
        maturityTimestamp = uint32(block.timestamp) + 365 * 86400; // in 1 year
        initTick = -16096; // 5%
    }

    function setConfigs() public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({
            marketId: marketId,
            quoteToken: address(mockToken),
            marketType: "compounding"
        });
        datedIrsProxy.setMarketConfiguration(
            marketId,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketId, maturityTimestamp), // 7 days
                markPriceBand: ud60x18(0.045e18), // 1%
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

    function test_scenario_B() public {
        setConfigs();

        // LP
        {   
            vm.mockCall(
                mockToken,
                abi.encodeWithSelector(IERC20.decimals.selector),
                abi.encode(6)
            );

            // action 
            executeDatedIrsMakerOrder({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 1,
                baseAmount: 10_000 * 1e6,
                tickLower: -19440, // 7%
                tickUpper: -10980 // 3%
            }); 

            PositionInfo memory positionInfo = PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3456411463,
                expectedUnfilledBaseShort: 6543588536,
                expectedUnfilledQuoteLong: 214656498, // compared to 204287264 without spread & slippage
                expectedUnfilledQuoteShort: 233727138 // compared to 253357903 without spread & slippage
            });
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);

        }

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick); // -16096

        vm.warp(block.timestamp + 86400 * 365 / 2);
        // liquidity index 1.010

        // short FT
        int256 executedBase1; int256 executedQuote1;
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 2,
                    baseAmount: -1_000 * 1e6
                }); 
            executedBase1 = executedBase;
            executedQuote1 = executedQuote;
            
            // executed amounts checks
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase1");
                // executedQuote = avgPrice * -executedBase * liquidityindex
                assertAlmostEq(executedQuote, int256(45301730), 1e6, "executedQuote1"); // 0.1% error
                // annualizedNotional = executedBase * liquidityindex * %timeTillMaturity
                // = 1000000000 * 1.01 * 0.5
                assertEq(annualizedNotional, -505000000, "annualizedNotional1");
            }
            // twap checks
            {
                uint256 price = checkNonAdjustedTwap(marketId, maturityTimestamp);
                // with non-zero lookback window
                uint256 twap = getAdjustedTwap(marketId, maturityTimestamp, 0); 
                assertGe(twap, price); // considers previous prices
                assertLe(twap, unwrap(VammTicks.getPriceFromTick(initTick).div(convert(100))));
                assertAlmostEq(twap, 0.05e18, 0.0001e18, "twap almost 5%");
            }
            
        }

        // currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);
        // current tick -15225 // 4.58%

        // long VT
        int256 executedBase2; int256 executedQuote2;
        {   
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 3,
                    baseAmount: 2_000 * 1e6
                }); 
            executedBase2 = executedBase;
            executedQuote2 = executedQuote;

            // executed amounts checks
            {
                assertEq(executedBase, 2_000 * 1e6, "executedBase2");
                // executedQuote = avgPrice * -executedBase * liquidityindex
                assertAlmostEq(executedQuote, int256(-107100205), 1e6, "executedQuote2"); // 0.1% error
                // annualizedNotional = executedBase * liquidityindex * %timeTillMaturity
                // = 2000000000 * 1.01 * 0.5
                assertEq(annualizedNotional, 1010000000, "annualizedNotional2");
            }
        }

        // currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);
        // current tick -17008 // 5.476%

        // long VT - account 4
        int256 executedBase4; int256 executedQuote4;
        {   
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 4,
                    baseAmount: 1_000 * 1e6
                }); 
            executedBase4 = executedBase;
            executedQuote4 = executedQuote;

            // executed amounts checks
            {
                assertEq(executedBase, 1_000 * 1e6, "executedBase3");
                // executedQuote = avgPrice * -executedBase * liquidityindex
                assertAlmostEq(executedQuote, int256(-61019748), 1e6, "executedQuote3");
                // annualizedNotional = executedBase * liquidityindex * %timeTillMaturity
                // = 1000000000 * 1.01 * 0.5
                assertEq(annualizedNotional, 505000000, "annualizedNotional3"); // todo: complete
                // 0.393 247 046
                // 1.010 000 000
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        console2.log("TICK", currentTick);
        // current tick -17963 // 6.02%

        // short FT - account 4
        int256 executedBase3; int256 executedQuote3;
        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 4,
                    baseAmount: -1_000 * 1e6
                }); 
            executedBase3 = executedBase;
            executedQuote3 = executedQuote;
            
            // executed amounts checks
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase4");
                // executedQuote = avgPrice * -executedBase * liquidityindex
                assertAlmostEq(executedQuote, int256(54998289), 1e6, "executedQuote4"); // 0.1% error
                // annualizedNotional = executedBase * liquidityindex * %timeTillMaturity
                // = 1000000000 * 1.01 * 0.5
                assertEq(annualizedNotional, -505000000, "annualizedNotional4");


                // quoteTokens = 2 * base * li * spread = 0.003 * 1000 * 1.01 * 2 = 6.06
                checkTakerFilledBalances(
                    datedIrsProxy,
                    PositionInfo({accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                    0,
                    -6060000,
                    0
                );
            }
            
        }

        // currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);
        // current tick -17008 // 5.476%

        invariantCheck();

        // 3/4 of time till maturity
        vm.warp(block.timestamp + 86400 * 365 / 4);
        // liquidity index 1.01505

        //////////// 1/4 UNTIL MATURITY ////////////

        // check balances LP
        console2.log("3/4 CHECK LP");
        {
            // unfilled (shouldn't have chganged since the mint)
            int128 liquidityPerTick = Utils.getLiquidityForBase(-19440, -10980, 10_000 * 1e6);
            checkUnfilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 2455744172,
                    // SignedMath.abs(VammHelpers.baseBetweenTicks(-19440, -16991, liquidityPerTick)), 
                expectedUnfilledBaseShort: 7544255827,
                    // SignedMath.abs(VammHelpers.baseBetweenTicks(-16991, -10980, liquidityPerTick)), 
                expectedUnfilledQuoteLong: 161671876,
                    // 2472909398 * 1.01505 * 0.054685
                expectedUnfilledQuoteShort: 287343450
            });

            // filled
            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalancePool: -(executedBase1 + executedBase2) + 1,
                expectedQuoteBalancePool: -(executedQuote1 + executedQuote2 + executedQuote3 + executedQuote4) - 1, // todo: complete
                expectedAccruedInterestPool: 12002165
            });
        }   

        // console2.log("check balances FT");

        // check balances FT
        console2.log("3/4 CHECK FT");
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: executedBase1, 
                expectedQuoteBalancePool: executedQuote1,
                expectedAccruedInterestPool: 6330099
            });
        }   

        // console2.log("check balances VT");

        // check balances VT
        console2.log("3/4 CHECK VT");
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: executedBase2, 
                expectedQuoteBalancePool: executedQuote2,
                expectedAccruedInterestPool: -16817264
            });
        }

        // check balances Account 4
        console2.log("3/4 CHECK ACC 4");
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: 0, 
                expectedQuoteBalancePool: executedQuote3 + executedQuote4, // -6060000
                expectedAccruedInterestPool: -1515000
            });
        }

        invariantCheck();
        vm.warp(block.timestamp + 86400 * 365 / 4 - 1);
        invariantCheck();
        vm.warp(block.timestamp + 2);

        //////////// AFTER MATURITY ////////////

        console2.log("------ AFTER MATURITY -----");
        // settle account 1
        (int256 settlementCashflowInQuote_1) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1
        });
        {   
            assertEq(settlementCashflowInQuote_1, 24004329, "settlementCashflowInQuote_1"); // todo: complete
            // note: after settlement, LP balances are not removed from Vamm storage

            // check settlement twice does not work
            vm.expectRevert(SetUtil.ValueNotInSet.selector);
            settle({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 1
            });
            // check maturity index was cached
            assertEq(1020000000634195839, unwrap(datedIrsProxy.getRateIndexMaturity(marketId, maturityTimestamp)));
        }

        // console2.log("settle account 2");
        // settle account 2
        (int256 settlementCashflowInQuote_2) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2
        });
        {
            assertEq(settlementCashflowInQuote_2, 12660198, "settlementCashflowInQuote_2");
            
            PositionInfo memory positionInfo = PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkZeroTakerFilledBalances(datedIrsProxy, positionInfo);
        }
        
        // console2.log("settle account 3");
        // settle account 3
        (int256 settlementCashflowInQuote_3) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 3
        });
        {
            assertEq(settlementCashflowInQuote_3, -33634528, "settlementCashflowInQuote_3");
            
            PositionInfo memory positionInfo = PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkZeroTakerFilledBalances(datedIrsProxy, positionInfo);
        }

        // console2.log("settle account 4");
        // settle account 4
        (int256 settlementCashflowInQuote_4) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 4
        });
        {
            assertEq(settlementCashflowInQuote_4, -3029999, "settlementCashflowInQuote_3");
            
            PositionInfo memory positionInfo = PositionInfo({accountId: 4, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkZeroTakerFilledBalances(datedIrsProxy, positionInfo);
        }

        // invariant check
        {
            assertAlmostEq(
                settlementCashflowInQuote_1 + settlementCashflowInQuote_2 + settlementCashflowInQuote_3 + settlementCashflowInQuote_4,
                int(0),
                3,
                "settlementCashflowSum"
            );
        }

    }
}