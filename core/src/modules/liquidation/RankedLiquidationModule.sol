/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ILiquidationHook} from "../../interfaces/external/ILiquidationHook.sol";
import {Account} from "../../storage/Account.sol";
import {AccountLiquidation} from "../../libraries/account/AccountLiquidation.sol";
import {Market} from "../../storage/Market.sol";
import {IRankedLiquidationModule} from "../../interfaces/liquidation/IRankedLiquidationModule.sol";
import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for ranked liquidated accounts
 * @dev See IRankedLiquidationModule
 */

contract RankedLiquidationModule is IRankedLiquidationModule {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using Market for Market.Data;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;
    using SafeCastI256 for int256;

    /**
     * Thrown when the pre liquidation hook returns an invalid response
     */
    error InvalidPreLiquidationHookResponse();

    /**
     * Thrown when the post liquidation hook returns an invalid response
     */
    error InvalidPostLiquidationHookResponse();

    /**
     * @inheritdoc IRankedLiquidationModule
     */
    function submitLiquidationBid(
        uint128 liquidatableAccountId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        account.submitLiquidationBid(liquidationBid);
    }

    /**
     * @inheritdoc IRankedLiquidationModule
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

        // todo: should in theory revert if the account is insolvent (& insurance fund
        // can't cover the insolvency after the liquidation (socialized losses via adl
        // should kick in here

        
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

    /**
     * @inheritdoc IRankedLiquidationModule
     */
    function executeTopRankedLiquidationBid(
        uint128 liquidatableAccountId,
        address queueQuoteToken,
        uint128 bidSubmissionKeeperId
    ) external override {

        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        account.executeTopRankedLiquidationBid(
            queueQuoteToken,
            bidSubmissionKeeperId
        );

    }
}
