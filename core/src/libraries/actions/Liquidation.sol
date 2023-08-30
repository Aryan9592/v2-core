/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "../../storage/Account.sol";
import "../AccountAutoExchange.sol";

/**
 * @title Library for executing liquidation logic.
 */
library Liquidation {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using Market for Market.Data;
    using SafeCastI256 for int256;

    /**
     * @notice Liquidates a single-token account
     * @param liquidatedAccountId The id of the account that is being liquidated
     * @param liquidatorAccountId Account id that will receive the rewards from the liquidation.
     * @return liquidatorRewardAmount Liquidator reward amount in terms of the account's settlement token
     */
    function liquidate(uint128 liquidatedAccountId, uint128 liquidatorAccountId, address collateralType)
        internal
        returns (uint256 liquidatorRewardAmount)
    {
        // todo: introduce liquidation logic
    }
}
