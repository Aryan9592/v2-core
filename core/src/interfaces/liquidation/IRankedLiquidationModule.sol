/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";

/**
 * @title Ranked Liquidation Engine interface
 */
interface IRankedLiquidationModule {
    // todo: add natspec
    function submitLiquidationBid(
        uint128 liquidateeAccountId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) external;

    // todo: add natspec
    function executeTopRankedLiquidationBid(
        uint128 liquidatedAccountId,
        address queueQuoteToken,
        uint128 bidSubmissionKeeperId
    ) external;
}

