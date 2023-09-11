/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {Market} from "../storage/Market.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";


// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for liquidated accounts
 * @dev See ILiquidationModule
 */

contract LiquidationModule is ILiquidationModule {
    using Account for Account.Data;
    using Market for Market.Data;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;

    /**
     * @inheritdoc ILiquidationModule
     */
    function getRequirementDeltasByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        override 
        returns (Account.MarginRequirementDeltas memory) 
    {
        return Account.exists(accountId).getRequirementDeltasByBubble(collateralType);
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
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) public {
        require(msg.sender == address(this));

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidationBid.liquidatorAccountId);

        // todo: need to mark active markets once liquidation orders are executed

        for (uint256 i = 0; i < liquidationBid.marketIds.length; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            Market.exists(marketId).executeLiquidationOrder(
                liquidatableAccountId,
                liquidationBid.liquidatorAccountId,
                liquidationBid.inputs[i]
            );
        }

        liquidatorAccount.imCheck(address(0));

    }

    function executeTopRankedLiquidationBid(
        uint128 liquidatableAccountId
    ) external override {

        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);

        if (block.timestamp > account.liquidationBidPriorityQueues.latestQueueEndTimestamp) {
            // the latest queue has expired, hence we cannot execute its top ranked liquidation bid
            revert Account.LiquidationBidPriorityQueueExpired(
                account.liquidationBidPriorityQueues.latestQueueId,
                account.liquidationBidPriorityQueues.latestQueueEndTimestamp
            );
        }

        // extract top ranked order

        LiquidationBidPriorityQueue.LiquidationBid memory topRankedLiquidationBid = account.liquidationBidPriorityQueues
        .priorityQueues[
        account.liquidationBidPriorityQueues.latestQueueId
        ].topBid();

        (bool success, bytes memory reason) = address(this).call(abi.encodeWithSignature(
            "executeLiquidationBid(uint128, LiquidationBidPriorityQueue.LiquidationBid memory)",
            liquidatableAccountId, topRankedLiquidationBid));

        // dequeue top bid it's successfully executed or not

        account.liquidationBidPriorityQueues.priorityQueues[
        account.liquidationBidPriorityQueues.latestQueueId
        ].dequeue();

    }


}
