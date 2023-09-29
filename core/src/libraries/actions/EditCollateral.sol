/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/token/ERC20Helper.sol";
import "../../storage/Account.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";

import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {Timer} from "@voltz-protocol/util-contracts/src/helpers/Timer.sol";

/**
 * @title Library for depositing and withdrawing logic.
 */
library EditCollateral {
    using Account for Account.Data;
    using ERC20Helper for address;
    using SafeCastU256 for uint256;
    using Timer for Timer.Data;

    /**
     * Thrown when backstop lp is attempting to withdraw, but
     * the withdraw period is not active.
     * @param backstopLpAccountId The account id of the backstop lp
     * @param blockTimestamp The current block's timestamp
     */
    error BackstopLpWithdrawPeriodInactive(uint128 backstopLpAccountId, uint256 blockTimestamp);

    /**
     * Thrown when a withdrawal for backstop lp is announced for
     * a different account.
     * @param accountId The account id for which the withdrawal was announced
     * @param backstopLpAccountId The account id of the backstop lp
     * @param blockTimestamp The current block's timestamp
     */
    error AccountIsNotBackstopLp(uint128 accountId, uint128 backstopLpAccountId, uint256 blockTimestamp);

    /**
     * Thrown when backstop lp withdraw cooldown period is already active
     * @param backstopLpAccountId The account id of the backstop lp
     * @param withdrawPeriodStartTimestamp The start timestamp of the withdraw period
     * @param blockTimestamp The current block's timestamp
     */
    error BackstopLpCooldownPeriodAlreadyActive(
        uint256 backstopLpAccountId, 
        uint256 withdrawPeriodStartTimestamp,
        uint256 blockTimestamp
    );
     
    /**
     * Thrown when backstop lp withdraw period is already active
     * @param backstopLpAccountId The account id of the backstop lp
     * @param blockTimestamp The current block's timestamp
     */
    error BackstopLpWithdrawPeriodAlreadyActive(uint256 backstopLpAccountId, uint256 blockTimestamp);

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
        account.updateNetCollateralDeposits(collateralType, tokenAmount.toInt());

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
        
        /// Check if account if backstop lp. If it is, make sure that 
        /// withdraw period is active.
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 backstopLpAccountId = collateralPool.backstopLPConfig.accountId;
        if (backstopLpAccountId == accountId) {
            if (!Timer.loadOrCreate(backstopLpTimerId(backstopLpAccountId)).isActive()) {
                revert BackstopLpWithdrawPeriodInactive(backstopLpAccountId, block.timestamp);
            }
        }

        account.updateNetCollateralDeposits(collateralType, -tokenAmount.toInt());

        collateralType.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(accountId, collateralType, tokenAmount, msg.sender, block.timestamp);
    }

    /**
     * @notice Backstop lp announces intention of withdrawal.
     */
    function announceBackstopLpWithdraw(uint128 accountId) internal {
        Account.Data storage account = Account.exists(accountId);

        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 backstopLpAccountId = collateralPool.backstopLPConfig.accountId;

        if (backstopLpAccountId != accountId) {
            revert AccountIsNotBackstopLp(accountId, backstopLpAccountId, block.timestamp);
        }

        Timer.Data storage backstopLpWithdrawTimer = Timer.loadOrCreate(backstopLpTimerId(backstopLpAccountId));
        if (block.timestamp < backstopLpWithdrawTimer.startTimestamp) {
            revert BackstopLpCooldownPeriodAlreadyActive(
                backstopLpAccountId, 
                backstopLpWithdrawTimer.startTimestamp, 
                block.timestamp
            );
        }
        if (backstopLpWithdrawTimer.isActive()) {
            revert BackstopLpWithdrawPeriodAlreadyActive(backstopLpAccountId, block.timestamp);
        }

        backstopLpWithdrawTimer.schedule(
            block.timestamp + collateralPool.backstopLPConfig.withdrawCooldownDurationInSeconds,
            collateralPool.backstopLPConfig.withdrawDurationInSeconds
        );
    }

    /**
     * @notice Computes the timer id used to track the withdrawal
     * period of the backstop lp
     */
    function backstopLpTimerId(uint128 accountId) internal pure returns(bytes32) {
        return keccak256(abi.encode("backstopLpWithdrawTimer", accountId));
    }
}
