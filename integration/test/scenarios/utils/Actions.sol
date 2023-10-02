pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {Utils} from "../../../src/utils/Utils.sol";
import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import {VammTicks} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";
import {DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";

/// @title Action helpers
abstract contract Actions is Test {
    
    function executeDatedIrsMakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (int256) {
        vm.startPrank(getCoreProxyAddress());

        int128 liquidityDelta = 
            Utils.getLiquidityForBase(tickLower, tickUpper, baseAmount);

        bytes memory inputs = abi.encode(
            maturityTimestamp,
            tickLower,
            tickUpper,
            liquidityDelta
        );
        (, int256 annualizedNotional) = 
            getDatedIrsProxy().executeMakerOrder(accountId, marketId, inputs);

        vm.stopPrank();

        return annualizedNotional;
    }

    function executeDatedIrsTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount,
        int24 tickLimit
    ) internal returns (int256, int256, int256) {
        vm.startPrank(getCoreProxyAddress());

        uint160 priceLimit = 
            TickMath.getSqrtRatioAtTick(tickLimit);

        bytes memory inputs = abi.encode(
            maturityTimestamp,
            baseAmount, 
            priceLimit
        );
        (bytes memory output, int256 annualizedNotional) = 
            getDatedIrsProxy().executeTakerOrder(accountId, marketId, inputs);

        (
            int256 executedBaseAmount,
            int256 executedQuoteAmount
        ) = abi.decode(output, (int256, int256));

        vm.stopPrank();

        return (executedBaseAmount, executedQuoteAmount, annualizedNotional);
    }

    function executeDatedIrsTakerOrder_noPriceLimit(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount
    ) internal returns (int256, int256, int256) {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(
            maturityTimestamp,
            baseAmount, 
            0
        );
        (bytes memory output, int256 annualizedNotional) = 
            getDatedIrsProxy().executeTakerOrder(accountId, marketId, inputs);

        (
            int256 executedBaseAmount,
            int256 executedQuoteAmount
        ) = abi.decode(output, (int256, int256));

        vm.stopPrank();

        return (executedBaseAmount, executedQuoteAmount, annualizedNotional);
    }

    function executeDatedIrsTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        int256 baseAmount
    ) internal {
        if (baseAmount > 0){
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, baseAmount,
                VammTicks.DEFAULT_MAX_TICK  - 1
            );
        } else {
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, baseAmount,
                VammTicks.DEFAULT_MIN_TICK + 1
            );
        }
    }

    function settle(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    ) internal returns (int256) {
        vm.startPrank(getCoreProxyAddress());

        bytes memory inputs = abi.encode(
            maturityTimestamp
        );
        (, int256 settlementCashflowInQuote) = 
            getDatedIrsProxy().completeOrder(accountId, marketId, inputs);

        vm.stopPrank();

        return settlementCashflowInQuote;
    }

    function getDatedIrsProxy() internal virtual returns(DatedIrsProxy);
    function getCoreProxyAddress() internal virtual returns(address);
}