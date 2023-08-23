/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";
import "../storage/CollateralConfiguration.sol";
import "@voltz-protocol/util-contracts/src/errors/ParameterError.sol";
import "../interfaces/ILiquidationModule.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import {mulUDxUint} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: consider introducing explicit reetrancy guards across the protocol
// todo: funnel a portfion of profits from liquidations to the default fund (nedes more research) (AB)
// todo: consider also performing auto-exchange in the event where a multi-token account is liquidatable (AB)
// todo: incorporate multi-token account liquidation flow, for that to work, we'll need to support (AB)
// position transferring liquidations where the incentive of the liquidator is not in terms of a given collateral token
// but rather represented as a discount on the liquidated position's price based on the twap

/**
 * @title Module for liquidated accounts
 * @dev See ILiquidationModule
 */

contract LiquidationModule is ILiquidationModule {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;

    /**
     * @inheritdoc ILiquidationModule
     */
    function getMarginRequirementsAndHighestUnrealizedLoss(uint128 accountId, address collateralType) 
        external 
        view 
        override 
        returns (Account.MarginRequirement memory mr) 
    {
        Account.Data storage account = Account.exists(accountId);
        mr = account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
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

    /**
     * @inheritdoc ILiquidationModule
     */
    function liquidate(uint128 liquidatedAccountId, uint128 liquidatorAccountId, address collateralType)
        external
        returns (uint256 liquidatorRewardAmount)
    {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account = Account.exists(liquidatedAccountId);

        account.ensureEnabledCollateralPool();

        if (account.accountMode == Account.MULTI_TOKEN_MODE) {
            revert AccountIsMultiToken(liquidatedAccountId);
        }

        Account.MarginRequirement memory mrPreClose = 
            account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        if (mrPreClose.isLMSatisfied) {
            revert AccountNotLiquidatable(liquidatedAccountId);
        }

        account.closeAccount(collateralType);

        Account.MarginRequirement memory mrPostClose = 
            account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        uint256 coverPreClose = mrPreClose.initialMarginRequirement + mrPreClose.highestUnrealizedLoss;
        uint256 coverPostClose = mrPostClose.initialMarginRequirement + mrPostClose.highestUnrealizedLoss;

        if (coverPostClose >= coverPreClose) {
            revert AccountExposureNotReduced(
                liquidatedAccountId,
                mrPreClose,
                mrPostClose
            );
        }

        liquidatorRewardAmount = extractLiquidatorReward(
            liquidatedAccountId,
            collateralType,
            coverPreClose,
            coverPostClose
        );

        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        liquidatorAccount.increaseCollateralBalance(collateralType, liquidatorRewardAmount);

        emit Liquidation(
            liquidatedAccountId,
            collateralType,
            msg.sender,
            liquidatorAccountId,
            liquidatorRewardAmount,
            mrPreClose,
            mrPostClose,
            block.timestamp
        );
    }
}
