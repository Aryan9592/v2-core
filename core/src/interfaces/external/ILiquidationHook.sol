/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";

interface ILiquidationHook {
  /**
   * @notice Liquidator-owned hook called before a liquidation bid is executed. 
   * Liquidator must register a non-zero address hook in the liquidation bid.
   * Hook should check that msg.sender is the Core and revert otherwise.
   * @param liquidatableAccountId The account to be liquidated
   * @param liquidationBid The liquidation bid submitted by the liquidator
   *  which is about to be executed
   */
  function preLiquidationHook(
    uint128 liquidatableAccountId,
    LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
  ) external;

  /**
   * @notice Liquidator-owned hook called after a liquidation bid is executed. 
   * Liquidator must register a non-zero address hook in the liquidation bid.
   * Hook should check that msg.sender is the Core and revert otherwise.
   * @param liquidatedAccountId The account that was liquidated
   * @param liquidationBid The liquidation bid submitted by the liquidator
   *  which was just executed
   */
  function postLiquidationHook(
    uint128 liquidatedAccountId,
    LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
  ) external;
}