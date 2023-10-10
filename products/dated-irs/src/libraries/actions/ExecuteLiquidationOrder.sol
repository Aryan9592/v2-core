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
import { FilledBalances } from "../DataTypes.sol";

/*
TODOs
    - add events
    - add natspec
    - add returns to execute liquidation order
    - make sure open interest trackers are updated after a liquidation order is executed
    - consider moving base filled calc (done in validate liq order) into portfolio?
    - make sure active market and maturity trackers of the liquidator are updated
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

    struct LiquidationOrderParams {
        uint128 liquidatableAccountId;
        uint128 liquidatorAccountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmountToBeLiquidated;
        uint160 priceLimit;
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
        FilledBalances memory filledBalances = portfolio.getAccountFilledBalances(
            maturityTimestamp,
            poolAddress
        );

        int256 baseBalancePool = filledBalances.base;

        baseAmountLiquidatableAccount = portfolio.positions[maturityTimestamp].base + baseBalancePool;

        // revert if base amount filled is zero
        if (baseAmountLiquidatableAccount == 0) {
            revert FilledBalanceZero(liquidatableAccountId, marketId, maturityTimestamp);
        }

        // revert if liquidation order direction is wrong
        //  if baseAmountToBeLiquidated*baseAmountLiquidatableAccount>0
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

    function computeMaxLiquidatableBase(
        int256 baseAmountLiquidatable
    ) private view returns (int256) {
        // todo: needs implementation
        return baseAmountLiquidatable;
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

        int256 maxBaseAmountLiquidatable = computeMaxLiquidatableBase(baseAmountLiquidatable);

        int256 baseAmountToBeLiquidated = params.baseAmountToBeLiquidated;

        if (maxBaseAmountLiquidatable.abs() < params.baseAmountToBeLiquidated.abs()) {
            baseAmountToBeLiquidated = -maxBaseAmountLiquidatable;
        }

        // todo base to quote conversion based on market price
        int256 quoteDeltaFromLiquidation = 0;

        Portfolio.Data storage portfolioLiquidatable = Portfolio.exists(
            params.liquidatableAccountId,
            params.marketId
        );

        Portfolio.Data storage portfolioLiquidator = Portfolio.loadOrCreate(
            params.liquidatorAccountId,
            params.marketId
        );

        portfolioLiquidatable.updatePosition(
            params.maturityTimestamp, baseAmountToBeLiquidated, quoteDeltaFromLiquidation
        );

        portfolioLiquidator.updatePosition(
            params.maturityTimestamp, -baseAmountToBeLiquidated, -quoteDeltaFromLiquidation
        );
    }

}
