/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {CollateralConfiguration} from "../storage/CollateralConfiguration.sol";
import {ICollateralModule} from "../interfaces/ICollateralModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {ERC20Helper} from "@voltz-protocol/util-contracts/src/token/ERC20Helper.sol";

/**
 * @title Module for managing user collateral.
 * @dev See ICollateralModule.
 */
contract CollateralModule is ICollateralModule {
    using ERC20Helper for address;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    /**
     * @inheritdoc ICollateralModule
     */
    function deposit(uint128 accountId, address collateralType, uint256 tokenAmount) external override {
        FeatureFlagSupport.ensureGlobalAccess();

        // check if collateral is enabled
        CollateralConfiguration.collateralEnabled(collateralType);

        // grab the account and check its existance
        Account.Data storage account = Account.exists(accountId);

        account.ensureEnabledCollateralPool();

        address depositFrom = msg.sender;
        address self = address(this);

        // check that this deposit does not reach the cap
        uint256 currentBalance = IERC20(collateralType).balanceOf(self);
        uint256 collateralCap = CollateralConfiguration.exists(collateralType).config.cap;
        if (collateralCap < currentBalance + tokenAmount) {
            revert CollateralCapExceeded(collateralType, collateralCap, currentBalance, tokenAmount);
        }

        // check allowance
        uint256 allowance = IERC20(collateralType).allowance(depositFrom, self);
        if (allowance < tokenAmount) {
            revert IERC20.InsufficientAllowance(tokenAmount, allowance);
        }

        // execute transfer
        collateralType.safeTransferFrom(depositFrom, self, tokenAmount);

        // update account collateral balance if necessary 
        account.increaseCollateralBalance(collateralType, tokenAmount);

        emit Deposited(accountId, collateralType, tokenAmount, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function withdraw(uint128 accountId, address collateralType, uint256 tokenAmount) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        
        Account.Data storage account =
            Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);

        account.ensureEnabledCollateralPool();

        account.decreaseCollateralBalance(collateralType, tokenAmount);

        account.imCheck(collateralType);

        collateralType.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(accountId, collateralType, tokenAmount, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountCollateralBalance(uint128 accountId, address collateralType)
        external
        view
        override
        returns (uint256 collateralBalance)
    {
        return Account.exists(accountId).getCollateralBalance(collateralType);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountWithdrawableCollateralBalance(uint128 accountId, address collateralType)
        external
        override
        view
        returns (uint256 collateralBalanceAvailable)
    {
        return Account.exists(accountId).getWithdrawableCollateralBalance(collateralType);
    }
}
