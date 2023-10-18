/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {AccountLiquidation} from "../../libraries/account/AccountLiquidation.sol";
import {IRankedLiquidationModule} from "../../interfaces/liquidation/IRankedLiquidationModule.sol";
import {LiquidationBidPriorityQueue} from "../../libraries/LiquidationBidPriorityQueue.sol";
import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

// todo: consider introducing explicit reetrancy guards across the protocol (e.g. twap - read only)

/**
 * @title Module for ranked liquidated accounts
 * @dev See IRankedLiquidationModule
 */

contract RankedLiquidationModule is IRankedLiquidationModule {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using SafeCastI256 for int256;

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
