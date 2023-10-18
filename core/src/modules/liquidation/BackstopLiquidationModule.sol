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
import {IBackstopLiquidationModule} from "../../interfaces/liquidation/IBackstopLiquidationModule.sol";

// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for backstop liquidated accounts
 * @dev See IBackstopLiquidationModule
 */

contract BackstopLiquidationModule is IBackstopLiquidationModule {
    using Account for Account.Data;
    using Market for Market.Data;
    using AccountLiquidation for Account.Data;

    /**
     * @inheritdoc IBackstopLiquidationModule
     */
    function executeBackstopLiquidation(
        uint128 liquidatableAccountId,
        uint128 keeperAccountId,
        address quoteToken,
        AccountLiquidation.LiquidationOrder[] memory backstopLPLiquidationOrders
    ) external override {
        // grab the liquidatable account and check its existance
        Account.Data storage account = Account.exists(liquidatableAccountId);
        account.executeBackstopLiquidation(keeperAccountId, quoteToken, backstopLPLiquidationOrders);
    }

    /**
     * @inheritdoc IBackstopLiquidationModule
     */
    function propagateADLOrder(
        uint128 marketId, 
        uint128 accountId,
        uint128 keeperAccountId, 
        uint32 maturityTimestamp, 
        bool isLong
    ) external override {
        Account.Data storage account = Account.exists(accountId);
        account.propagateADLOrder(marketId, keeperAccountId, maturityTimestamp, isLong);
    }
}
