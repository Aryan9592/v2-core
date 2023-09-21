pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {Utils} from "../../../src/utils/Utils.sol";
import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import {DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";

/// @title Action helpers
abstract contract Actions is Test {
    
    function executeDatedIrsMakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        address user,
        int256 baseAmount,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (int256) {
        vm.startPrank(user);

        int128 liquidityDelta = 
            Utils.getLiquidityForBase(tickLower, tickUpper, baseAmount);

        bytes memory inputs = abi.encode(
            maturityTimestamp,
            tickLower,
            tickUpper,
            liquidityDelta
        );
        (, int256 annualizedNotional) = 
            datedIrsProxy().executeMakerOrder(accountId, marketId, inputs);

        vm.stopPrank();

        return annualizedNotional;
    }

    function executeDatedIrsTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId,
        address user,
        int256 baseAmount,
        int24 tickLimit
    ) internal returns (int256, int256, int256) {
        vm.startPrank(user);

        uint160 priceLimit = 
            TickMath.getSqrtRatioAtTick(tickLimit);

        bytes memory inputs = abi.encode(
            maturityTimestamp,
            baseAmount, 
            priceLimit
        );
        (bytes memory output, int256 annualizedNotional) = 
            datedIrsProxy().executeTakerOrder(accountId, marketId, inputs);

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
        address user,
        int256 baseAmount
    ) internal {
        if (baseAmount > 0){
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, user, baseAmount,
                TickMath.DEFAULT_MIN_TICK
            );
        } else {
            executeDatedIrsTakerOrder(
                marketId, maturityTimestamp, accountId, user, baseAmount,
                TickMath.DEFAULT_MAX_TICK
            );
        }
    }

    function datedIrsProxy() internal virtual returns(DatedIrsProxy);
}