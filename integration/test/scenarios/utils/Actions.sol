pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { VammTicks } from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";
import { DatedIrsProxy } from "../../../src/proxies/DatedIrs.sol";

/// @title Action helpers
abstract contract Actions is Test {
    function executeDatedIrsMakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount,
        int24 tickLower,
        int24 tickUpper
    )
        internal
    {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(maturityTimestamp, tickLower, tickUpper, baseAmount);

        // todo: return fees and check fees in scenarios
        getDatedIrsProxy().executeMakerOrder(accountId, marketId, 0, inputs);

        vm.stopPrank();
    }

    function executeDatedIrsTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount,
        int24 tickLimit
    )
        internal
        returns (int256, int256)
    {
        vm.startPrank(getCoreProxyAddress());

        uint160 priceLimit = TickMath.getSqrtRatioAtTick(tickLimit);

        bytes memory inputs = abi.encode(maturityTimestamp, baseAmount, priceLimit);
        // todo: return fees and check fees in scenarios
        (bytes memory output,,) = getDatedIrsProxy().executeTakerOrder(accountId, marketId, 0, inputs);

        (int256 executedBaseAmount, int256 executedQuoteAmount) = abi.decode(output, (int256, int256));

        vm.stopPrank();

        return (executedBaseAmount, executedQuoteAmount);
    }

    function executeDatedIrsTakerOrder_noPriceLimit(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount
    )
        internal
        returns (int256, int256)
    {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(maturityTimestamp, baseAmount, 0);
        // todo: return fees and check fees in scenarios
        (bytes memory output,,) = getDatedIrsProxy().executeTakerOrder(accountId, marketId, 0, inputs);

        (int256 executedBaseAmount, int256 executedQuoteAmount) = abi.decode(output, (int256, int256));

        vm.stopPrank();

        return (executedBaseAmount, executedQuoteAmount);
    }

    function executeDatedIrsTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount
    )
        internal
    {
        if (baseAmount > 0) {
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, baseAmount, VammTicks.DEFAULT_MAX_TICK - 1
            );
        } else {
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, baseAmount, VammTicks.DEFAULT_MIN_TICK + 1
            );
        }
    }

    function settle(uint128 marketId, uint32 maturityTimestamp, uint128 accountId) internal returns (int256) {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(maturityTimestamp);
        (, int256 settlementCashflowInQuote) = getDatedIrsProxy().executePropagateCashflow(accountId, marketId, inputs);

        vm.stopPrank();

        return settlementCashflowInQuote;
    }

    function executeLiquidation(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmountToBeLiquidated,
        uint256 priceLimit
    ) internal {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(maturityTimestamp, baseAmountToBeLiquidated, priceLimit);
        getDatedIrsProxy().executeLiquidationOrder(
            liquidatableAccountId, liquidatorAccountId, marketId, inputs
        );

        vm.stopPrank();
    }

    function closeAllUnfilledOrders(uint128 marketId, uint128 accountId) internal returns (uint256) {
        vm.startPrank(getCoreProxyAddress());

        uint256 closedUnfilledBasePool = getDatedIrsProxy().closeAllUnfilledOrders(marketId, accountId);

        vm.stopPrank();

        return closedUnfilledBasePool;
    }

    function getDatedIrsProxy() internal virtual returns (DatedIrsProxy);
    function getCoreProxyAddress() internal virtual returns (address);
}
