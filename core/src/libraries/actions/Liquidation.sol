/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../../storage/Account.sol";
import {LiquidationBidPriorityQueue} from "../LiquidationBidPriorityQueue.sol";

/**
 * @title Library for executing liquidation logic.
 */
library Liquidation {

    using Account for Account.Data;

    // todo: add events

    function submitLiquidationBid(
        uint128 liquidatedAccountId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        // grab the liquidated account and check its existance
        Account.Data storage account = Account.exists(liquidatedAccountId);

        account.submitLiquidationBid(liquidationBid);

    }

    function executeTopRankedLiquidationBid(
        uint128 liquidatedAccountId
    ) internal {
        // grab the liquidated account and check its existance
        Account.Data storage account = Account.exists(liquidatedAccountId);

        account.executeTopRankedLiquidationBid();
    }



}
