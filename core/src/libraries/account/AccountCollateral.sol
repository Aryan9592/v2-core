/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import {Account} from "../../storage/Account.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {GlobalCollateralConfiguration} from  "../../storage/GlobalCollateralConfiguration.sol";

/**
 * @title Object for tracking account collaterals.
 */
library AccountCollateral {
    using Account for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using GlobalCollateralConfiguration for GlobalCollateralConfiguration.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;

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

    function updateNetCollateralShares(
        Account.Data storage self, 
        address collateralType, 
        int256 shares
    ) private {
        // update collateral balance
        self.collateralShares[collateralType] += shares;

        // update the active collateral list
        if (self.collateralShares[collateralType] != 0) {
            if (!self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.add(collateralType);
            }
        } else if (self.collateralShares[collateralType] == 0) {
            if (self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.remove(collateralType);
            }
        }

        // update the corresponding collateral pool balance if exists
        if (self.firstMarketId != 0) {
            self.getCollateralPool().updateCollateralShares(collateralType, shares);
        }

        // emit event
        emit AccountCollateralUpdated(self.id, collateralType, shares, block.timestamp);
    }

    /**
     * @dev Updates the account's net deposits
     */
    function updateNetCollateralDeposits(
        Account.Data storage self, 
        address collateralType, 
        int256 assets
    ) internal {
        // Convert assets to shares
        GlobalCollateralConfiguration.Data storage globalConfig = GlobalCollateralConfiguration.exists(collateralType);
        int256 shares = globalConfig.convertToShares(assets);
        updateNetCollateralShares(self, collateralType, shares);
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the account
     */
    function getAccountNetCollateralDeposits(
        Account.Data storage self,
        address collateralType
    )
        internal
        view
        returns (int256)
    {
        GlobalCollateralConfiguration.Data storage globalConfig = GlobalCollateralConfiguration.exists(collateralType);
        return globalConfig.convertToAssets(self.collateralShares[collateralType]);
    }

    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getAccountWithdrawableCollateralBalance(Account.Data storage self, address collateralType)
        internal
        view
        returns (uint256 /* withdrawableCollateralBalance */)
    {
        Account.MarginInfo memory marginInfoBubble = self.getMarginInfoByBubble(collateralType);
        int256 withdrawableBalanceBubble = SignedMath.max(
            0,
            SignedMath.min(
                marginInfoBubble.initialDelta, 
                marginInfoBubble.realBalance
            )
        );

        if (withdrawableBalanceBubble <= 0) {
            return 0;
        }

        Account.MarginInfo memory marginInfoCollateral = 
            self.getMarginInfoByCollateralType(
                collateralType, 
                self.getCollateralPool().riskConfig.imMultiplier,
                self.getCollateralPool().riskConfig.mmrMultiplier
            );
        
        int256 withdrawableBalanceCollateral = SignedMath.max(
            0,
            SignedMath.min(
                withdrawableBalanceBubble, 
                marginInfoCollateral.realBalance
            )
        );

        return withdrawableBalanceCollateral.toUint();
    }
}
