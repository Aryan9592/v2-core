/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";

/**
 * @title Liquidation Engine interface
 */
interface ILiquidationModule {
    /**
     * @dev Thrown when an account is not liquidatable but liquidation is triggered on it.
     */
    error AccountNotLiquidatable(uint128 accountId);


    /**
     * @dev Thrown when attempting to liquidate a multi-token account in a single-token manner
     */
    error AccountIsMultiToken(uint128 accountId);


    /**
     * @dev Thrown when attempting to liquidate a single-token account in a multi-token manner
     */
    error AccountIsSingleToken(uint128 accountId);


    /**
     * @dev Thrown when an account exposure is not reduced when liquidated.
     */
    error AccountExposureNotReduced(
        uint128 accountId,
        Account.MarginRequirement mrPreClose,
        Account.MarginRequirement mrPostClose
    );

    /**
     * @notice Emitted when an account is liquidated.
     * @param liquidatedAccountId The id of the account that was liquidated.
     * @param collateralType The collateral type of the account that was liquidated
     * @param liquidatorAccountId Account id that will receive the rewards from the liquidation.
     * @param liquidatorRewardAmount The liquidator reward amount
     * @param sender The address that triggers the liquidation.
     * @param blockTimestamp The current block timestamp.
     */
    event Liquidation(
        uint128 indexed liquidatedAccountId,
        address indexed collateralType,
        address sender,
        uint128 liquidatorAccountId,
        uint256 liquidatorRewardAmount,
        Account.MarginRequirement mrPreClose,
        Account.MarginRequirement mrPostClose,
        uint256 blockTimestamp
    );

    /**
     * @notice Get the im and lm requirements and highest unrealized loss along with the flags for im or lm satisfied 
     * @param accountId The id of the account that is being checked
     * @param collateralType The collateral type of the account that is being checked
     * @return mr Margin requirement and highest unrealized loss information
     */
    function getMarginRequirementsAndHighestUnrealizedLoss(uint128 accountId, address collateralType) 
        external 
        view 
        returns (Account.MarginRequirement memory mr);

    /**
     * @notice Liquidates a single-token account
     * @param liquidatedAccountId The id of the account that is being liquidated
     * @param liquidatorAccountId Account id that will receive the rewards from the liquidation.
     * @return liquidatorRewardAmount Liquidator reward amount in terms of the account's settlement token
     */
    function liquidate(uint128 liquidatedAccountId, uint128 liquidatorAccountId, address collateralType)
        external
        returns (uint256 liquidatorRewardAmount);
}
