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

import { IPool } from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

import { UD60x18, ud, wrap, unwrap } from "@prb/math/UD60x18.sol";

contract ScenarioD is ScenarioSetup, AssertionHelpers, Actions, Checks {
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
        uint128[] memory accountIds = new uint128[](2);
        accountIds[0] = 1;
        accountIds[1] = 2;

        checkTotalFilledBalances(datedIrsProxy, marketId, maturityTimestamp, accountIds);
    }

    function setUp() public {
        super.datedIrsSetup();
        marketId = 1;
        maturityTimestamp = uint32(block.timestamp) + 365 * 86_400; // in 1 year
        initTick = -16_096; // 5%
    }

    function setConfigs(UD60x18 priceImpactPhi, UD60x18 spread) public {
        vm.startPrank(owner);

        //////// MARKET MANAGER CONFIGURATION ////////

        datedIrsProxy.createMarket({ marketId: marketId, quoteToken: address(mockUsdc), marketType: "compounding" });

        datedIrsProxy.setMarketConfiguration(
            marketId,
            Market.MarketConfiguration({
                poolAddress: address(vammProxy),
                twapLookbackWindow: twapLookbackWindow(marketId, maturityTimestamp), // 7 days
                markPriceBand: ud(0.045e18), // 4.5%
                protocolFeeConfig: Market.FeeConfiguration({ atomicMakerFee: ud(1e16), atomicTakerFee: ud(5e16) }),
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

        datedIrsProxy.setMarketMaturityConfiguration(
            marketId,
            maturityTimestamp,
            Market.MarketMaturityConfiguration({
                riskMatrixRowId: 0,
                tenorInSeconds: 0,
                phi: priceImpactPhi,
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
            spread: spread,
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

    function test_scenario_D_no_slippage_no_price_impact() public {
        setConfigs(ud(0), ud(0));
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (FT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: -100 * 1e6
            });

            // check outputs
            assertEq(executedBase, -100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -15_227, "tick after 10 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 47_446_712_689_052_953, "twap after 10 days when order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 47_446_712_689_052_953, "twap after 10 days when order = 100");
        }

        for (uint256 i = 10; i < 20; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -16_097, "tick after 20 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 48_279_467_813_104_117, "twap after 20 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 48_279_467_813_104_117, "twap after 20 days with order = 100");
        }

        for (uint256 i = 20; i < 30; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -17_005, "tick after 30 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 52_783_672_690_232_108, "twap after 30 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 52_783_672_690_232_108, "twap after 30 days with order = 100");
        }
    }

    function test_scenario_D_slippage_no_price_impact() public {
        setConfigs(ud(0), ud(0.003e18));
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (FT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: -100 * 1e6
            });

            // check outputs
            assertEq(executedBase, -100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -15_227, "tick after 10 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 47_446_712_689_052_953, "twap after 10 days when order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 50_446_712_689_052_953, "twap after 10 days when order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 44_446_712_689_052_953, "twap after 10 days when order = -100");
        }

        for (uint256 i = 10; i < 20; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -16_097, "tick after 20 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 48_279_467_813_104_117, "twap after 20 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 51_279_467_813_104_117, "twap after 20 days with order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 45_279_467_813_104_117, "twap after 20 days with order = -100");
        }

        for (uint256 i = 20; i < 30; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -17_005, "tick after 30 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 52_783_672_690_232_108, "twap after 30 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 55_783_672_690_232_108, "twap after 30 days with order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 49_783_672_690_232_108, "twap after 30 days with order = -100");
        }
    }

    function test_scenario_D_slippage_price_impact() public {
        setConfigs(ud(0.0001e18), ud(0.003e18));
        uint256 start = block.timestamp;

        vm.mockCall(mockUsdc, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(6));

        // t = 0: account 1 (LP)
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10_000 * 1e6,
            tickLower: -19_500, // 7%
            tickUpper: -11_040 // 3%
         });

        for (uint256 i = 0; i < 10; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (FT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: -100 * 1e6
            });

            // check outputs
            assertEq(executedBase, -100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -15_227, "tick after 10 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 47_446_712_689_052_953, "twap after 10 days when order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 51_446_712_689_052_952, "twap after 10 days when order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 43_446_712_689_052_954, "twap after 10 days when order = -100");
        }

        for (uint256 i = 10; i < 20; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -16_097, "tick after 20 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 48_279_467_813_104_117, "twap after 20 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 52_279_467_813_104_116, "twap after 20 days with order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 44_279_467_813_104_118, "twap after 20 days with order = -100");
        }

        for (uint256 i = 20; i < 30; i++) {
            vm.warp(start + 86_400 * 365 * 3 / 4 + 86_400 * i);

            // account 2 (VT)
            (int256 executedBase,) = executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 100 * 1e6
            });

            // check outputs
            assertEq(executedBase, 100 * 1e6, "executedBase");

            invariantCheck();
        }

        {
            int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
            assertEq(currentTick, -17_005, "tick after 30 days");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Zero,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 0)
            );
            assertEq(twap, 52_783_672_690_232_108, "twap after 30 days with order = 0");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Long,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, 100e18)
            );
            assertEq(twap, 56_783_672_690_232_107, "twap after 30 days with order = 100");
        }

        {
            uint256 twap = getAdjustedTwap(
                marketId,
                maturityTimestamp,
                IPool.OrderDirection.Short,
                datedIrsProxy.getPercentualSlippage(marketId, maturityTimestamp, -100e18)
            );
            assertEq(twap, 48_783_672_690_232_109, "twap after 30 days with order = -100");
        }
    }
}
