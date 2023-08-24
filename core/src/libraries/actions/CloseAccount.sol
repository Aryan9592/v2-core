/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "../../storage/Account.sol";

/**
 * @title Library for account closing logic.
 */
library CloseAccount {
    using Account for Account.Data;
    using Market for Market.Data;

    /**
     * @notice Emitted when account token with id `accountId` is closed.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param sender The initiator of the account closure.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountClosed(uint128 indexed accountId, uint128 indexed marketId, address sender, uint256 blockTimestamp);

    /// @notice attempts to close all the unfilled and filled positions of a given account in a given market (marketId)
    function closeAccount(uint128 marketId, uint128 accountId) internal {
        FeatureFlagSupport.ensureGlobalAccess();

        Account.Data storage account = Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);

        account.ensureEnabledCollateralPool();

        Market.exists(marketId).closeAccount(accountId);
        emit AccountClosed(accountId, marketId, msg.sender, block.timestamp);
    }
}
