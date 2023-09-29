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
        uint128[] memory accountIds = new uint128[](3);
        accountIds[0] = 1;
        accountIds[1] = 2;
        accountIds[2] = 3;

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
                markPriceBand: ud60x18(0.01e18), // 0.1%
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

    function test_scenario_A() public {
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
                expectedUnfilledQuoteLong: 204287264,
                expectedUnfilledQuoteShort: 253357903
            });
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);

        }

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);

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
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                // executedQuote = 1 + avgPrice[0.04788] * -executedBase * liquidityindex
                // = 0.04788 * 1000000000 * 1.01
                assertAlmostEq(executedQuote, int256(48358800), 1e6, "executedQuote1"); // 0.1% error
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

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);

        // current tick -15210 // 4.5764%

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
                assertEq(executedBase, 2_000 * 1e6, "executedBase");
                // executedQuote = 1 + avgPrice[0.04788] * -executedBase * liquidityindex
                // = 0.04788 * 1000000000 * 1.01
                assertAlmostEq(executedQuote, int256(-101209059), 1e6, "executedQuote1"); // 0.1% error
                // annualizedNotional = executedBase * liquidityindex * %timeTillMaturity
                // = 1000000000 * 1.01 * 0.5
                assertEq(annualizedNotional, 1010000000, "annualizedNotional1");
            }
        }
        invariantCheck();

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        // console2.log("TICK", currentTick);
        // current tick -16991 // 5.4685%

        // 3/4 of time till maturity
        vm.warp(block.timestamp + 86400 * 365 / 4);
        // liquidity index 1.01505

        // check balances LP
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
                expectedUnfilledQuoteLong: 154194135,
                    // 2472909398 * 1.01505 * 0.054685
                expectedUnfilledQuoteShort: 310315709
            });

            // filled
            checkPoolFilledBalances({
                poolAddress: address(vammProxy),
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalancePool: -(executedBase1 + executedBase2) + 1, 
                expectedQuoteBalancePool: -(executedQuote1 + executedQuote2) - 1,
                expectedAccruedInterestPool: 8214665
            });
        }   

        // console2.log("check balances FT");

        // check balances FT
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: executedBase1, 
                expectedQuoteBalancePool: executedQuote1,
                expectedAccruedInterestPool: 7087599
            });
        }   

        // console2.log("check balances VT");

        // check balances VT
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 3, marketId: marketId, maturityTimestamp: maturityTimestamp});
            checkZeroUnfilledBalances(address(vammProxy), positionInfo);
            checkZeroPoolFilledBalances(address(vammProxy), positionInfo);
            checkTakerFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedBaseBalancePool: executedBase2, 
                expectedQuoteBalancePool: executedQuote2,
                expectedAccruedInterestPool: -15302264
            });
        }

        invariantCheck();

        vm.warp(block.timestamp + 86400 * 365 / 4 - 1);

        invariantCheck();

        vm.warp(block.timestamp + 2);

        // settle account 1
        (int256 settlementCashflowInQuote_1) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1
        });
        {   
            assertEq(settlementCashflowInQuote_1, 16429329, "settlementCashflowInQuote_1"); // todo: complete
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

        // settle account 2
        (int256 settlementCashflowInQuote_2) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2
        });
            
        assertEq(settlementCashflowInQuote_2, 14175197, "settlementCashflowInQuote_2");
            
        // settle account 3
        (int256 settlementCashflowInQuote_3) = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 3
        });

        assertEq(settlementCashflowInQuote_3, -30604528, "settlementCashflowInQuote_3");

        // invariant check
        {
            assertAlmostEq(
                settlementCashflowInQuote_1 + settlementCashflowInQuote_2 + settlementCashflowInQuote_3,
                int(0),
                3,
                "settlementCashflowSum"
            );
        }

        invariantCheck();
    }
}