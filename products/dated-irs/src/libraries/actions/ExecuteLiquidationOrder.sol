/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { Portfolio } from "../../storage/Portfolio.sol";
import { Market } from "../../storage/Market.sol";
import { SignedMath } from "oz/utils/math/SignedMath.sol";
import { UD60x18, ud } from "@prb/math/UD60x18.sol";
import { ExposureHelpers } from "../ExposureHelpers.sol";
import { LiquidationOrderParams } from "../DataTypes.sol";

/*
TODOs
    - add events
    - add natspec
    - add returns to execute liquidation order
    - make sure open interest trackers are updated after a liquidation order is executed
    - consider moving base filled calc (done in validate liq order) into portfolio?
    - liquidatable portfolio is retrieved twice in the liquidation order flow (once in validation and once in main body)
*/

/**
 * @title Library for liquidation orders logic.
 */
library ExecuteLiquidationOrder {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;
    using SignedMath for int256;

    /**
     * @dev Thrown if liquidation order is invalid
     */
    error InvalidLiquidationOrder(LiquidationOrderParams params, bytes32 reason);

    /**
     * @dev Thrown if liquidation order hits the price limit set by the liquidator
     */
    error PriceLimitBreached(LiquidationOrderParams params);

    function isPriceLimitBreached(
        bool isLiquidationLong,
        UD60x18 liquidationPrice,
        UD60x18 priceLimit
    )
        private
        pure
        returns (bool)
    {
        // if liquidation is long (from the perspective of liquidatee), the liquidator is taking the short side

        if (isLiquidationLong && liquidationPrice.lt(priceLimit)) {
            return true;
        }

        if (!isLiquidationLong && liquidationPrice.gt(priceLimit)) {
            return true;
        }

        return false;
    }

    function validateLiquidationOrder(LiquidationOrderParams memory params) internal view {
        // revert if liquidation order size is 0
        if (params.baseAmountToBeLiquidated == 0) {
            revert InvalidLiquidationOrder(params, "LiquidationOrderZero");
        }

        address poolAddress = Market.exists(params.marketId).marketConfig.poolAddress;

        // retrieve base amount filled by the liquidatable account
        int256 accountBase = Portfolio.exists(params.liquidatableAccountId, params.marketId).getAccountFilledBalances(
            params.maturityTimestamp, poolAddress
        ).base;

        // revert if base amount filled is zero
        if (accountBase == 0) {
            revert InvalidLiquidationOrder(params, "AccountFilledBaseZero");
        }

        // revert if the liquidation order size is too big or is in the wrong direction
        if (accountBase > 0) {
            if (params.baseAmountToBeLiquidated > 0) {
                revert InvalidLiquidationOrder(params, "WrongLiquidationDirection");
            }

            if (accountBase + params.baseAmountToBeLiquidated < 0) {
                revert InvalidLiquidationOrder(params, "LiquidationOrderTooBig");
            }
        } else {
            if (params.baseAmountToBeLiquidated < 0) {
                revert InvalidLiquidationOrder(params, "WrongLiquidationDirection");
            }

            if (accountBase + params.baseAmountToBeLiquidated > 0) {
                revert InvalidLiquidationOrder(params, "LiquidationOrderTooBig");
            }
        }
    }

    function executeLiquidationOrder(LiquidationOrderParams memory params) internal {
        // todo: this is support for partial orders but we block them in the validation
        // decide which option to keep: allow or deny partial liquidation orders

        validateLiquidationOrder(params);

        address poolAddress = Market.exists(params.marketId).marketConfig.poolAddress;

        UD60x18 liquidationPrice =
            ExposureHelpers.computeTwap(params.marketId, params.maturityTimestamp, poolAddress, 0);

        if (isPriceLimitBreached(params.baseAmountToBeLiquidated > 0, liquidationPrice, ud(params.priceLimit))) {
            revert PriceLimitBreached(params);
        }

        int256 quoteDeltaFromLiquidation =
            ExposureHelpers.computeQuoteDelta(params.baseAmountToBeLiquidated, liquidationPrice, params.marketId);

        Portfolio.propagateMatchedOrder(
            Portfolio.exists(params.liquidatableAccountId, params.marketId),
            Portfolio.loadOrCreate(params.liquidatorAccountId, params.marketId),
            params.baseAmountToBeLiquidated,
            quoteDeltaFromLiquidation,
            params.maturityTimestamp
        );
    }
}
