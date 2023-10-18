/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {Market} from "../../storage/Market.sol";
import {AccountLiquidation} from "../../libraries/account/AccountLiquidation.sol";
import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";
import {ICommonLiquidationModule} from "../../interfaces/liquidation/ICommonLiquidationModule.sol";
import {ILiquidationHook} from "../../interfaces/external/ILiquidationHook.sol";

import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for liquidated accounts
 * @dev See ICommonLiquidationModule
 */

contract CommonLiquidationModule is ICommonLiquidationModule {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using Market for Market.Data;

    /**
     * Thrown when the pre liquidation hook returns an invalid response
     */
    error InvalidPreLiquidationHookResponse();

    /**
     * Thrown when the post liquidation hook returns an invalid response
     */
    error InvalidPostLiquidationHookResponse();

    /**
     * @inheritdoc ICommonLiquidationModule
     */
    function closeAllUnfilledOrders(uint128 liquidatableAccountId, uint128 liquidatorAccountId) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);
        account.closeAllUnfilledOrders(liquidatorAccountId);
    }

    /**
     * @inheritdoc ICommonLiquidationModule
     */
    function executeLiquidationBid(
        uint128 liquidatableAccountId,
        uint128 bidSubmissionKeeperId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) public override {
        // todo: need to mark active markets once liquidation orders are executed
        // todo: also need to make sure the collateral pool id of the liquidator is updated accordingly as well
        // if it doesn't belong to any collateral pool
        require(msg.sender == address(this));

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidationBid.liquidatorAccountId);

        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        if (liquidationBid.hookAddress != address(0)) {
            if (
                ILiquidationHook(liquidationBid.hookAddress).preLiquidationHook(
                    liquidatableAccountId,
                    liquidationBid
                ) != ILiquidationHook.preLiquidationHook.selector
            ) {
                revert InvalidPreLiquidationHookResponse();
            }
        }

        uint256 rawLMRBefore = account.getMarginInfoByBubble(liquidationBid.quoteToken).rawInfo.rawLiquidationMarginRequirement;

        for (uint256 i = 0; i < liquidationBid.marketIds.length; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            Market.exists(marketId).executeLiquidationOrder(
                liquidatableAccountId,
                liquidationBid.liquidatorAccountId,
                liquidationBid.inputs[i]
            );
        }

        uint256 rawLMRAfter = account.getMarginInfoByBubble(liquidationBid.quoteToken).rawInfo.rawLiquidationMarginRequirement;

        if (rawLMRAfter > rawLMRBefore) {
            revert AccountLiquidation.LiquidationCausedNegativeLMDeltaChange(account.id, rawLMRBefore, rawLMRAfter);
        }
        uint256 liquidationPenalty = mulUDxUint(
            liquidationBid.liquidatorRewardParameter,
            rawLMRBefore - rawLMRAfter
        );

        account.distributeLiquidationPenalty(
            liquidatorAccount,
            liquidationPenalty,
            liquidationBid.quoteToken,
            bidSubmissionKeeperId
        );

        liquidatorAccount.imCheck();
        
        if (liquidationBid.hookAddress != address(0)) {
            if (
                ILiquidationHook(liquidationBid.hookAddress).postLiquidationHook(
                    liquidatableAccountId,
                    liquidationBid
                ) != ILiquidationHook.postLiquidationHook.selector
            ) {
                revert InvalidPostLiquidationHookResponse();
            }
        }
    }
}
