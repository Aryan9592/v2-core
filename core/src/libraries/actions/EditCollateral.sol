/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "@voltz-protocol/util-contracts/src/token/ERC20Helper.sol";
import "../../storage/Account.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";

/**
 * @title Library for depositing and withdrawing logic.
 */
library EditCollateral {
    using Account for Account.Data;
    using ERC20Helper for address;

    /**
     * @notice Emitted when `tokenAmount` of collateral of type `collateralType` is deposited to account `accountId` by `sender`.
     * @param accountId The id of the account that deposited collateral.
     * @param collateralType The address of the collateral that was deposited.
     * @param tokenAmount The amount of collateral that was deposited, denominated in the token's native decimal representation.
     * @param sender The address of the account that triggered the deposit.
     * @param blockTimestamp The current block timestamp.
     */
    event Deposited(
        uint128 indexed accountId,
        address indexed collateralType,
        uint256 tokenAmount,
        address indexed sender,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when `tokenAmount` of collateral of type `collateralType` is withdrawn from account `accountId` by `sender`.
     * @param accountId The id of the account that withdrew collateral.
     * @param collateralType The address of the collateral that was withdrawn.
     * @param tokenAmount The amount of collateral that was withdrawn, denominated in the token's native decimal representation.
     * @param sender The address of the account that triggered the withdrawal.
     * @param blockTimestamp The current block timestamp.
     */
    event Withdrawn(
        uint128 indexed accountId, 
        address indexed collateralType, 
        uint256 tokenAmount, 
        address indexed sender, 
        uint256 blockTimestamp
    );

    /**
     * @notice Deposits `tokenAmount` of collateral of type `collateralType` into account `accountId`.
     * @dev Anyone can deposit into anyone's active account without restriction.
     * @param accountId The id of the account that is making the deposit.
     * @param collateralType The address of the token to be deposited.
     * @param tokenAmount The amount being deposited, denominated in the token's native decimal representation.
     *
     * Emits a {Deposited} event.
     */
    function deposit(uint128 accountId, address collateralType, uint256 tokenAmount) internal {
        // grab the account and check its existance
        Account.Data storage account = Account.exists(accountId);

        // check if collateral is enabled
        if (account.firstMarketId != 0) {
            uint128 collateralPoolId = account.getCollateralPool().id;
            CollateralConfiguration.collateralEnabled(collateralPoolId, collateralType);
        }

        address depositFrom = msg.sender;
        address self = address(this);

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
     * @notice Withdraws `tokenAmount` of collateral of type `collateralType` from account `accountId`.
     * @param accountId The id of the account that is making the withdrawal.
     * @param collateralType The address of the token to be withdrawn.
     * @param tokenAmount The amount being withdrawn, denominated in the token's native decimal representation.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the account
     *
     * Emits a {Withdrawn} event.
     *
     */
    function withdraw(uint128 accountId, address collateralType, uint256 tokenAmount) internal {
        Account.Data storage account = Account.exists(accountId);

        account.decreaseCollateralBalance(collateralType, tokenAmount);

        collateralType.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(accountId, collateralType, tokenAmount, msg.sender, block.timestamp);
    }
}
