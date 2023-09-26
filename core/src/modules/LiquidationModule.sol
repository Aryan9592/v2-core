/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ILiquidationHook} from "../interfaces/external/ILiquidationHook.sol";
import {Account} from "../storage/Account.sol";
import {AccountLiquidation} from "../libraries/account/AccountLiquidation.sol";
import {Market} from "../storage/Market.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for liquidated accounts
 * @dev See ILiquidationModule
 */

contract LiquidationModule is ILiquidationModule {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using Market for Market.Data;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;
    using SafeCastI256 for int256;

    /**
     * @inheritdoc ILiquidationModule
     */
    function getMarginInfoByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        override 
        returns (Account.MarginInfo memory) 
    {
        return Account.exists(accountId).getMarginInfoByBubble(collateralType);
    }

    /**
     * @inheritdoc ILiquidationModule
     */
    function submitLiquidationBid(
        uint128 liquidatableAccountId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        account.submitLiquidationBid(liquidationBid);
    }

    function executeLiquidationBid(
        uint128 liquidatableAccountId,
        uint128 bidSubmissionKeeperId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) public {
        // todo: need to mark active markets once liquidation orders are executed
        // todo: also need to make sure the collateral pool id of the liquidator is updated accordingly as well
        // if it doesn't belong to any collateral pool
        require(msg.sender == address(this));

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidationBid.liquidatorAccountId);

        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        if (liquidationBid.hookAddress != address(0)) {
            ILiquidationHook(liquidationBid.hookAddress).preLiquidationHook(
                liquidatableAccountId,
                liquidationBid
            );
        }

        int256 lmDeltaBeforeLiquidation = account.getMarginInfoByBubble(liquidationBid.quoteToken).liquidationDelta;

        for (uint256 i = 0; i < liquidationBid.marketIds.length; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            Market.exists(marketId).executeLiquidationOrder(
                liquidatableAccountId,
                liquidationBid.liquidatorAccountId,
                liquidationBid.inputs[i]
            );
        }

        int256 lmDeltaChange =
        account.getMarginInfoByBubble(liquidationBid.quoteToken).liquidationDelta - lmDeltaBeforeLiquidation;
        if (lmDeltaChange < 0) {
            revert AccountLiquidation.LiquidationCausedNegativeLMDeltaChange(account.id, lmDeltaChange);
        }
        uint256 liquidationPenalty = mulUDxUint(
            liquidationBid.liquidatorRewardParameter,
            lmDeltaChange.toUint()
        );

        account.distributeLiquidationPenalty(
            liquidatorAccount,
            liquidationPenalty,
            liquidationBid.quoteToken,
            bidSubmissionKeeperId
        );

        liquidatorAccount.imCheck(address(0));

        // todo: should in theory revert if the account is insolvent (& insurance fund
        // can't cover the insolvency after the liquidation (socialized losses via adl
        // should kick in here

        
        if (liquidationBid.hookAddress != address(0)) {
            ILiquidationHook(liquidationBid.hookAddress).postLiquidationHook(
                liquidatableAccountId,
                liquidationBid
            );
        }
    }

    /**
     * @inheritdoc ILiquidationModule
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


    /**
     * @inheritdoc ILiquidationModule
     */
    function executeDutchLiquidation(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes memory inputs
    ) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        account.executeDutchLiquidation(liquidatorAccountId, marketId, inputs);
    }

    function closeAllUnfilledOrders(uint128 liquidatableAccountId, uint128 liquidatorAccountId) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        account.closeAllUnfilledOrders(liquidatorAccountId);
    }

}
