/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {AccountLiquidation} from "../../libraries/account/AccountLiquidation.sol";

/**
 * @title Dutch Liquidation Engine interface
 */
interface IBackstopLiquidationModule {
    // todo: add natspec
    function executeBackstopLiquidation(
        uint128 liquidatableAccountId,
        uint128 keeperAccountId,
        address quoteToken,
        AccountLiquidation.LiquidationOrder[] memory backstopLPLiquidationOrders
    ) external;

    // todo: add natspec
    function propagateADLOrder(
        uint128 marketId,
        uint128 accountId, 
        uint128 keeperAccountId,
        uint32 maturityTimestamp, 
        bool isLong
    ) external;
}