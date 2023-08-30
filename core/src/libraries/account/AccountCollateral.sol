/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import {Account} from "../../storage/Account.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";

/**
 * @title Object for tracking account collaterals.
 */
library AccountCollateral {
    using Account for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
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

    function increaseCollateralShares(
        Account.Data storage self, 
        CollateralConfiguration.Data storage collateral, 
        uint256 shares
    ) private {
        address collateralAddress = collateral.cachedConfig.tokenAddress;

        // increase collateral balance
        self.collateralShares[collateralAddress] += shares;

        // add the collateral type to the active collaterals if missing
        if (self.collateralShares[collateralAddress] > 0) {
            if (!self.activeCollaterals.contains(collateralAddress)) {
                self.activeCollaterals.add(collateralAddress);
            }
        }

        // update the corresponding collateral pool balance if exists
        if (self.firstMarketId != 0) {
            self.getCollateralPool().increaseCollateralShares(collateral, shares);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralAddress, shares.toInt(), block.timestamp);
    }

    /**
     * @dev Increments the account's collateral balance.
     */
    function increaseCollateralBalance(
        Account.Data storage self, 
        CollateralConfiguration.Data storage collateral, 
        uint256 assets
    ) internal {
        // Convert assets to shares
        uint256 shares = collateral.convertToShares(assets);

        increaseCollateralShares(self, collateral, shares);
    }

    function decreaseCollateralShares(
        Account.Data storage self, 
        CollateralConfiguration.Data storage collateral,
        uint256 shares
    ) private {
        address collateralAddress = collateral.cachedConfig.tokenAddress;

        // check collateral balance and revert if not sufficient
        if (self.collateralShares[collateralAddress] < shares) {
            revert InsufficientCollateral(self.id, collateralAddress, shares);
        }

        // decrease collateral balance
        self.collateralShares[collateralAddress] -= shares;

        // remove the collateral type from the active collaterals if balance goes to zero
        if (self.collateralShares[collateralAddress] == 0) {
            if (self.activeCollaterals.contains(collateralAddress)) {
                self.activeCollaterals.remove(collateralAddress);
            }
        }

        // update the corresponding collateral pool balance
        if (self.firstMarketId != 0) {
            self.getCollateralPool().decreaseCollateralShares(collateral, shares);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralAddress, -shares.toInt(), block.timestamp);
    }

    /**
     * @dev Decrements the account's collateral balance.
     */
    function decreaseCollateralBalance(
        Account.Data storage self, 
        CollateralConfiguration.Data storage collateral,
        uint256 assets
    ) internal {
        // Convert assets to shares
        uint256 shares = collateral.convertToShares(assets);

        // Decrease the account shares balance
        decreaseCollateralShares(self, collateral, shares);
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the account
     */
    function getCollateralBalance(
        Account.Data storage self,
        CollateralConfiguration.Data storage collateral
    )
        internal
        view
        returns (uint256)
    {
        return collateral.convertToAssets(
            self.collateralShares[collateral.cachedConfig.tokenAddress]
        );
    }

    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getWithdrawableCollateralBalance(Account.Data storage self, address collateralType)
        internal
        view
        returns (uint256 /* withdrawableCollateralBalance */)
    {
        // get account value in the given collateral
        Account.MarginRequirementDeltas memory deltas  = 
            self.getRequirementDeltasByBubble(collateralType);

        if (deltas.initialDelta <= 0) {
            return 0;
        }

        // get the account collateral balance
        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        // get minimum between account collateral balance and available collateral
        return (collateralBalance <= deltas.initialDelta.toUint()) 
            ? collateralBalance
            : deltas.initialDelta.toUint();
    }
}
