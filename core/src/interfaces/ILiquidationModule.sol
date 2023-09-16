/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";

/**
 * @title Liquidation Engine interface
 */
interface ILiquidationModule {

    /**
     * @notice Get the initial and liquidation margin requirements and highest unrealized loss
     * (if maker positions were to be filled) along with the flags that specify if the initial or liquidation margin
     * requirements are satisfied.
     * @param accountId The id of the account that is being checked
     * @param collateralType The collateral type for which the margin requirements are checked,
     * where the collateral type is the centre of a given collateral bubble
     * @return Margin requirement information object
     */
    function getMarginInfoByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        returns (Account.MarginInfo memory);

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

    // todo: add natspec
    function executeDutchLiquidation(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes memory inputs
    ) external;

    // todo: add natspec
    function closeAllUnfilledOrders(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId
    ) external;

}
