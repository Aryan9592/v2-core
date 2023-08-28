/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {mulUDxUint} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import {Account} from "../storage/Account.sol";
import {CollateralConfiguration} from "../storage/CollateralBubble.sol";
import {CollateralPool} from "../storage/CollateralPool.sol";
import {Market} from "../storage/Market.sol";

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
        if (self.firstMarketId != 0) {
            self.getCollateralPool().increaseCollateralBalance(collateralType, amount);
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
        if (self.firstMarketId != 0) {
            self.getCollateralPool().decreaseCollateralBalance(collateralType, amount);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the account
     */
    function getCollateralBalance(Account.Data storage self, address collateralType)
        internal
        view
        returns (uint256)
    {
        return self.collateralBalances[collateralType];
    }

    /**
     * @dev Returns the total weighted collateral in USD
     */
    function getWeightedBaseCollateralBalance(Account.Data storage self, address baseToken) 
        internal 
        view
        returns (uint256 weightedBaseCollateralBalance) 
    {
        // if the account does not belong to any collateral pool, return the collateral balance of the asset
        if (self.firstMarketId == 0) {
            return self.getCollateralBalance(baseToken);
        }

        // fetch the corresponding collateral pool
        uint128 collateralPoolId = self.getCollateralPool().id;

        // fetch all the sub-tokens of the base token and their exchange information
        CollateralConfiguration.ExchangeInfo[] memory subs = CollateralConfiguration.getSubTokens(collateralPoolId, baseToken);

        for (uint256 i = 0; i < subs.length; i++) {
            // get collateral balance in this specific token
            uint256 collateralBalance = self.getCollateralBalance(subs[i].token);

            // convert it into base token and apply haircut
            weightedBaseCollateralBalance += mulUDxUint(
                subs[i].price.mul(subs[i].exchangeHaircut), 
                collateralBalance
            );
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
