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
     * @dev Thrown when an account is not liquidatable but liquidation is triggered on it.
     */
    error AccountNotLiquidatable(uint128 accountId);
    /**
     * @dev Thrown when attempting to liquidate a multi-token account in a single-token manner
     */
    error AccountIsMultiToken(uint128 accountId);
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
     * @notice Liquidates a single-token account
     * @param liquidatedAccountId The id of the account that is being liquidated
     * @param liquidatorAccountId Account id that will receive the rewards from the liquidation.
     * @return liquidatorRewardAmount Liquidator reward amount in terms of the account's settlement token
     */
    function liquidate(uint128 liquidatedAccountId, uint128 liquidatorAccountId, address collateralType)
        internal
        returns (uint256 liquidatorRewardAmount)
    {
        // Account.Data storage account = Account.exists(liquidatedAccountId);

        // if (account.accountMode == Account.MULTI_TOKEN_MODE) {
        //     revert AccountIsMultiToken(liquidatedAccountId);
        // }

        // Account.MarginRequirement memory mrPreClose = 
        //     account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        // if (mrPreClose.isLMSatisfied) {
        //     revert AccountNotLiquidatable(liquidatedAccountId);
        // }

        // account.closeAccount(collateralType);

        // Account.MarginRequirement memory mrPostClose = 
        //     account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        // uint256 coverPreClose = mrPreClose.initialMarginRequirement + mrPreClose.highestUnrealizedLoss;
        // uint256 coverPostClose = mrPostClose.initialMarginRequirement + mrPostClose.highestUnrealizedLoss;

        // if (coverPostClose >= coverPreClose) {
        //     revert AccountExposureNotReduced(
        //         liquidatedAccountId,
        //         mrPreClose,
        //         mrPostClose
        //     );
        // }

        // liquidatorRewardAmount = extractLiquidatorReward(
        //     liquidatedAccountId,
        //     collateralType,
        //     coverPreClose,
        //     coverPostClose
        // );

        // Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        // liquidatorAccount.increaseCollateralBalance(collateralType, liquidatorRewardAmount);

        // emit Liquidation(
        //     liquidatedAccountId,
        //     collateralType,
        //     msg.sender,
        //     liquidatorAccountId,
        //     liquidatorRewardAmount,
        //     mrPreClose,
        //     mrPostClose,
        //     block.timestamp
        // );
    }

    function extractLiquidatorReward(
        uint128 liquidatedAccountId,
        address collateralType,
        uint256 coverPreClose,
        uint256 coverPostClose
    ) internal returns (uint256 liquidatorRewardAmount) {
        Account.Data storage account = Account.exists(liquidatedAccountId);

        UD60x18 liquidatorRewardParameter = account.getCollateralPool().riskConfig.liquidatorRewardParameter;
    
        liquidatorRewardAmount = mulUDxUint(liquidatorRewardParameter, coverPreClose - coverPostClose);
        account.decreaseCollateralBalance(collateralType, liquidatorRewardAmount);
    }
}
