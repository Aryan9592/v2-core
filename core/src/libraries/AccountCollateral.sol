/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import "../storage/Account.sol";
import "../storage/CollateralConfiguration.sol";
import "../storage/CollateralPool.sol";
import "../storage/Market.sol";

/**
 * @title Object for tracking account collaterals.
 */
library AccountCollateral {
    using Account for Account.Data;
    using Market for Market.Data;
    using CollateralPool for CollateralPool.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.AddressSet;

    /**
     * @dev Thrown when an account does not have sufficient collateral.
     */
    error InsufficientCollateral(uint128 accountId, address collateralType, uint256 requestedAmount);

    /**
     * @notice Emitted when collateral balance of account token with id `accountId` is updated.
     * @param accountId The id of the account.
     * @param collateralType The address of the collateral type.
     * @param tokenAmount The change delta of the collateral balance.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountCollateralUpdated(
        uint128 indexed accountId, 
        address indexed collateralType, 
        int256 tokenAmount, 
        uint256 blockTimestamp
    );

    /**
     * @dev Increments the account's collateral balance.
     */
    function increaseCollateralBalance(Account.Data storage self, address collateralType, uint256 amount) internal {
        // increase collateral balance
        self.collateralBalances[collateralType] += amount;

        // add the collateral type to the active collaterals if missing
        if (self.collateralBalances[collateralType] > 0) {
            if (!self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.add(collateralType);
            }
        }

        // update the corresponding collateral pool balance if exists
        if (self.firstMarketId > 0) {
            Market.exists(self.firstMarketId)
                .getCollateralPool()
                .increaseCollateralBalance(collateralType, amount);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralType, amount.toInt(), block.timestamp);
    }

    /**
     * @dev Decrements the account's collateral balance.
     */
    function decreaseCollateralBalance(Account.Data storage self, address collateralType, uint256 amount) internal {
        // check collateral balance and revert if not sufficient
        if (self.collateralBalances[collateralType] < amount) {
            revert InsufficientCollateral(self.id, collateralType, amount);
        }

        // decrease collateral balance
        self.collateralBalances[collateralType] -= amount;

        // remove the collateral type from the active collaterals if balance goes to zero
        if (self.collateralBalances[collateralType] == 0) {
            if (self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.remove(collateralType);
            }
        }

        // update the corresponding collateral pool balance
        if (self.firstMarketId > 0) {
            Market.exists(self.firstMarketId)
                .getCollateralPool()
                .decreaseCollateralBalance(collateralType, amount);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    function getWeightedCollateralBalanceInUSD(Account.Data storage self) 
    internal 
    view
    returns (uint256 weightedCollateralBalanceInUSD) 
    {
        for (uint256 i = 1; i <= self.activeCollaterals.length(); i++) {
            address collateralType = self.activeCollaterals.valueAt(i);

            // get the collateral balance of the account in this collateral type
            uint256 collateralBalance = self.getCollateralBalance(collateralType);

            // aggregate the corresponding weighted amount in USD 
            weightedCollateralBalanceInUSD += 
                CollateralConfiguration.load(collateralType).getWeightedCollateralInUSD(collateralBalance);
        }
    }

    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getWithdrawableCollateralBalance(Account.Data storage self, address collateralType)
        internal
        view
        returns (uint256 withdrawableCollateralBalance)
    {
        // get im and lm requirements and highest unrealized pnl in collateral
        Account.MarginRequirement memory mr = 
            self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        // get the account collateral balance
        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        // get minimum between account collateral balance and available collateral
        withdrawableCollateralBalance = 
            (collateralBalance >= mr.availableCollateralBalance) 
                ? mr.availableCollateralBalance
                : collateralBalance;
    }
}
