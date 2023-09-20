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

/*
TODOs
    - add events
    - add natspec
    - add returns to execute liquidation order
    - make sure open interest trackers are updated after a liquidation order is executed
    - consider moving base filled calc (done in validate liq order) into portfolio?
*/

/**
 * @title Library for liquidation orders logic.
*/
library ExecuteLiquidationOrder {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @dev Thrown if liquidation order is in the wrong direction
     */
    error WrongLiquidationDirection(int256 baseAmountLiquidatableAccount, LiquidationOrderParams liqOrderParams);

    /**
     * @dev Thrown if liquidation order size is zero
     */
    error LiquidationOrderZero(LiquidationOrderParams liqOrderParams);

    /**
     * @dev Thrown if filled balance of liquidatable account is zero
     */
    error FilledBalanceZero(LiquidationOrderParams liqOrderParams);

    struct LiquidationOrderParams {
        uint128 liquidatableAccountId;
        uint128 liquidatorAccountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmountToBeLiquidated;
        uint160 priceLimit;
    }


    function validateLiquidationOrder(
        LiquidationOrderParams memory params
    ) internal view {

        // revert if liquidation order size is 0
        if (params.baseAmountToBeLiquidated == 0) {
            revert LiquidationOrderZero(params);
        }

        Market.Data storage market = Market.exists(params.marketId);
        Portfolio.Data storage portfolio = Portfolio.exists(params.liquidatableAccountId, params.marketId);

        // retrieve base amount filled by the liquidatable account

        (int256 baseBalancePool,,) = IPool(market.marketConfig.poolAddress).getAccountFilledBalances(
            params.marketId,
            params.maturityTimestamp,
            params.liquidatableAccountId
        );

        int256 baseAmountLiquidatableAccount = portfolio.positions[params.maturityTimestamp].baseBalance
        + baseBalancePool;

        // revert if base amount filled is zero
        if (baseAmountLiquidatableAccount == 0) {
            revert FilledBalanceZero(params);
        }

        // revert if liquidation order direction is wrong
        //  if baseAmountToBeLiquidated*baseAmountLiquidatableAccount>0
        if ( (params.baseAmountToBeLiquidated > 0 && baseAmountLiquidatableAccount > 0)
            || (params.baseAmountToBeLiquidated < 0 && baseAmountLiquidatableAccount < 0) ) {
            revert WrongLiquidationDirection(baseAmountLiquidatableAccount, params);
        }

    }

    function executeLiquidationOrder(
        LiquidationOrderParams memory params
    ) internal {
        validateLiquidationOrder(params);
    }

}
