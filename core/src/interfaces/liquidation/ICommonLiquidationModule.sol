/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";

/**
 * @title Common Liquidation Engine interface
 */
interface ICommonLiquidationModule {
    // todo: add natspec
    function closeAllUnfilledOrders(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId
    ) external;

    // todo: add natspec
    function executeLiquidationBid(
        uint128 liquidatableAccountId,
        uint128 bidSubmissionKeeperId,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) external;
}
