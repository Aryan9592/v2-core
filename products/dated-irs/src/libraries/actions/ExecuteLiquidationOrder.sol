/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


import {Portfolio} from "../../storage/Portfolio.sol";
import {Market} from "../../storage/Market.sol";
import {IPool} from "../../interfaces/IPool.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";
import { UD60x18, ud } from "@prb/math/UD60x18.sol";
import "../ExposureHelpers.sol";

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
     * @dev Thrown if liquidation order is in the wrong direction
     */
    error WrongLiquidationDirection(
        uint128 liquidatableAccountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmountLiquidatableAccount);

    /**
     * @dev Thrown if liquidation order size is zero
     */
    error LiquidationOrderZero(uint128 liquidatableAccountId, uint128 marketId, uint32 maturityTimestamp);

    /**
     * @dev Thrown if filled balance of liquidatable account is zero
     */
    error FilledBalanceZero(uint128 liquidatableAccountId, uint128 marketId, uint32 maturityTimestamp);

    /**
     * @dev Thrown if liquidation order hits the price limit set by the liquidator
     */
    error PriceLimitBreached(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        uint32 maturityTimestamp
    );

    struct LiquidationOrderParams {
        uint128 liquidatableAccountId;
        uint128 liquidatorAccountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmountToBeLiquidated;
        uint256 priceLimit;
    }

    function isPriceLimitBreached(
        bool isLiquidationLong,
        UD60x18 liquidationPrice,
        UD60x18 priceLimit
    ) private pure returns (bool)  {

        // if liquidation is long (from the perspective of liquidatee), the liquidator is taking the short side

        if (isLiquidationLong && liquidationPrice.lt(priceLimit)) {
            return true;
        }

        if (!isLiquidationLong && liquidationPrice.gt(priceLimit)) {
            return true;
        }

        return false;
    }

    function validateLiquidationOrder(
        uint128 liquidatableAccountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmountToBeLiquidated
    ) internal view returns (int256 baseAmountLiquidatableAccount) {

        // revert if liquidation order size is 0
        if (baseAmountToBeLiquidated == 0) {
            revert LiquidationOrderZero(liquidatableAccountId, marketId, maturityTimestamp);
        }

        Portfolio.Data storage portfolio = Portfolio.exists(liquidatableAccountId, marketId);

        Market.Data storage market = Market.exists(marketId);
        address poolAddress = market.marketConfig.poolAddress;

        // retrieve base amount filled by the liquidatable account
        baseAmountLiquidatableAccount = portfolio.getAccountFilledBalances(
            maturityTimestamp,
            poolAddress
        ).base;

        // revert if base amount filled is zero
        if (baseAmountLiquidatableAccount == 0) {
            revert FilledBalanceZero(liquidatableAccountId, marketId, maturityTimestamp);
        }

        // revert if liquidation order direction is wrong
        if ( (baseAmountToBeLiquidated > 0 && baseAmountLiquidatableAccount > 0)
            || (baseAmountToBeLiquidated < 0 && baseAmountLiquidatableAccount < 0) ) {
            revert WrongLiquidationDirection(
                liquidatableAccountId,
                marketId,
                maturityTimestamp,
                baseAmountLiquidatableAccount
            );
        }

    }

    function executeLiquidationOrder(
        LiquidationOrderParams memory params
    ) internal {

        int256 baseAmountLiquidatable = validateLiquidationOrder(
            params.liquidatableAccountId,
            params.marketId,
            params.maturityTimestamp,
            params.baseAmountToBeLiquidated
        );

        int256 baseAmountToBeLiquidated = params.baseAmountToBeLiquidated;

        if (baseAmountLiquidatable.abs() < params.baseAmountToBeLiquidated.abs()) {
            baseAmountToBeLiquidated = -baseAmountLiquidatable;
        }

        Market.Data storage market = Market.exists(params.marketId);

        UD60x18 liquidationPrice = ExposureHelpers.computeTwap(
            params.marketId,
            params.maturityTimestamp,
            market.marketConfig.poolAddress,
            0
        );

        if (isPriceLimitBreached(baseAmountToBeLiquidated > 0, liquidationPrice, ud(params.priceLimit))) {
            revert PriceLimitBreached(
                params.liquidatableAccountId,
                params.liquidatorAccountId,
                params.marketId,
                params.maturityTimestamp
            );
        }

        int256 quoteDeltaFromLiquidation = ExposureHelpers.computeQuoteDelta(
            baseAmountToBeLiquidated,
            liquidationPrice,
            params.marketId
        );

        Portfolio.Data storage portfolioLiquidatable = Portfolio.exists(
            params.liquidatableAccountId,
            params.marketId
        );

        Portfolio.Data storage portfolioLiquidator = Portfolio.loadOrCreate(
            params.liquidatorAccountId,
            params.marketId
        );

        Portfolio.propagateMatchedOrder(
            portfolioLiquidatable,
            portfolioLiquidator,
            baseAmountToBeLiquidated,
            quoteDeltaFromLiquidation,
            params.maturityTimestamp
        );
    }

}
