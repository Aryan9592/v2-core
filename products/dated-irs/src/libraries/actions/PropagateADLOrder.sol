/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import {Portfolio} from "../../storage/Portfolio.sol";
import {Market} from "../../storage/Market.sol";
import {ExposureHelpers} from "../../libraries/ExposureHelpers.sol";


/*
TODOs
    - add pre propagate order execution checks
    - revert if account has zero exposure to propagate
    - make sure accrued cashflows are also propagated
*/


/**
 * @title Library for propagating adl orders
*/
library PropagateADLOrder {

    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @dev Thrown when attempting to propagate an adl order in the wrong direction
     */
    error WrongADLPropagationDirection();


    function propagateADLOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        bool isLong
    ) internal {

        Market.Data storage market = Market.exists(marketId);
        address poolAddress = market.marketConfig.poolAddress;

        Portfolio.Data storage accountPortfolio = Portfolio.exists(accountId, marketId);

        ExposureHelpers.PoolExposureState memory accountPoolState = accountPortfolio.getPoolExposureState(
            maturityTimestamp,
            poolAddress
        );

        int256 accountBaseFilled = accountPoolState.baseBalance + accountPoolState.baseBalancePool;

        if ( (isLong && accountBaseFilled > 0) || (!isLong && accountBaseFilled < 0)) {
            revert WrongADLPropagationDirection();
        }

        Portfolio.Data storage adlPortfolio = isLong ? Portfolio.exists(type(uint128).max - 1, market.id)
            : Portfolio.exists(type(uint128).max - 2, market.id);

        // todo: calculate the share of base and quote to propagate
        int256 baseToPropagate = 0;
        int256 quoteToPropagate = 0;

        accountPortfolio.updatePosition(maturityTimestamp, baseToPropagate, quoteToPropagate);
        adlPortfolio.updatePosition(maturityTimestamp, -baseToPropagate, -quoteToPropagate);

    }


}