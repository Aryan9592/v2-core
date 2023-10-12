pragma solidity >=0.8.19;

import { Actions } from "./utils/Actions.sol";
import { AssertionHelpers } from "./utils/AssertionHelpers.sol";
import { Checks } from "./utils/Checks.sol";
import { Constants } from "./utils/Constants.sol";
import { ScenarioSetup } from "./utils/ScenarioSetup.sol";

import { DatedIrsProxy } from "../../src/proxies/DatedIrs.sol";
import { VammProxy } from "../../src/proxies/Vamm.sol";

import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { Market } from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";

import { DatedIrsVamm } from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { VammTicks } from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";
import { VammHelpers } from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammHelpers.sol";

import { ud60x18, UD60x18, unwrap, wrap } from "@prb/math/UD60x18.sol";


contract ScenarioTLP is ScenarioSetup, AssertionHelpers, Actions, Checks {
    address internal user1;
    address internal user2;

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
        uint128[] memory accountIds = new uint128[](2);
        accountIds[0] = 1;
        accountIds[1] = 2;

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

    function test_scenario_TLP() public {
        setConfigs();
        uint256 start = block.timestamp;

        vm.mockCall(
            mockUsdc,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(6)
        );

        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -16096, "current tick");

        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3%
        }); 

        // check account 1
        {   
            PositionInfo memory positionInfo = PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp});
            
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 3523858284,
                expectedUnfilledBaseShort: 6476141715,
                expectedUnfilledQuoteLong: 219470934,
                expectedUnfilledQuoteShort: 232071370
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        vm.warp(start + 86400 * 365 * 1 / 4);

        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 1,
                    baseAmount: -1_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, -1_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(45102186), "executedQuote");
                assertEq(annualizedNotional, -753750000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -15227, "current tick");

        // check account 1
        {
            PositionInfo memory positionInfo = PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp});

            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: positionInfo,
                expectedUnfilledBaseLong: 4523743141,
                expectedUnfilledBaseShort: 5476256858,
                expectedUnfilledQuoteLong: 271694824,
                expectedUnfilledQuoteShort: 188134497
            });

            checkZeroFilledBalances(datedIrsProxy, positionInfo);
        }

        vm.warp(start + 86400 * 365 * 2 / 4);
        
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2,
            baseAmount: 10_000 * 1e6,
            tickLower: -19500, // 7%
            tickUpper: -11040 // 3%
        }); 

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 4523743141,
                expectedUnfilledBaseShort: 5476256858,
                expectedUnfilledQuoteLong: 273046539,
                expectedUnfilledQuoteShort: 189070490
            });

            checkZeroFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp})
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 4523743141,
                expectedUnfilledBaseShort: 5476256858,
                expectedUnfilledQuoteLong: 273046539,
                expectedUnfilledQuoteShort: 189070490
            });

            checkZeroFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp})
            });
        }

        invariantCheck();

        vm.warp(start + 86400 * 365 * 3 / 4);

        {
            // action 
            (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
                executeDatedIrsTakerOrder_noPriceLimit({
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    accountId: 1,
                    baseAmount: 4_000 * 1e6
                }); 
            
            // check outputs
            {
                assertEq(executedBase, 4_000 * 1e6, "executedBase");
                assertEq(executedQuote, int256(-215597769), "executedQuote");
                assertEq(annualizedNotional, 1015000000, "annualizedNotional");
            }
        }

        currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        assertEq(currentTick, -17005, "current tick");

        // check account 1
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 2523411734,
                expectedUnfilledBaseShort: 7476588265,
                expectedUnfilledQuoteLong: 166578898,
                expectedUnfilledQuoteShort: 285643820
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: 2000000001, 
                expectedQuoteBalance: -107798885,
                expectedAccruedInterest: 0
            });
        }

        // check account 2
        {
            checkUnfilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedUnfilledBaseLong: 2523411734,
                expectedUnfilledBaseShort: 7476588265,
                expectedUnfilledQuoteLong: 166578898,
                expectedUnfilledQuoteShort: 285643820
            });

            checkFilledBalances({
                datedIrsProxy: datedIrsProxy,
                positionInfo: 
                    PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
                expectedBaseBalance: -1999999999, 
                expectedQuoteBalance: 107798884,
                expectedAccruedInterest: 0
            });
        }

        invariantCheck();

        vm.warp(start + 86400 * 365 * 7 / 8);

        invariantCheck();

        vm.warp(start + 86400 * 365);

        int256[] memory settlementCashflows = new int256[](2);

        // settle account 1
        settlementCashflows[0] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1
        });
        assertEq(settlementCashflows[0], -16949721, "settlement cashflow 1");

        // settle account 2
        settlementCashflows[1] = settle({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 2
        });
            
        assertEq(settlementCashflows[1], 16949721, "settlement cashflow 2");
            
        // invariant check
        {
            int256 netSettlementCashflow = 0;
            for (uint256 i = 0; i < settlementCashflows.length; i++) {
                netSettlementCashflow += settlementCashflows[i];
            }

            assertAlmostEq(
                netSettlementCashflow,
                int(0),
                3,
                "net settlement cashflow"
            );
        }

        invariantCheck();
    }
}