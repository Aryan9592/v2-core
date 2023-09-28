/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {AccountAutoExchange} from "../account/AccountAutoExchange.sol";
import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
/*
TODOs
    - make sure re-entrancy is not possible with collateral transfers
*/


/**
 * @title Library to trigger auto-exchange
 */
library AutoExchange {

    using AccountAutoExchange for Account.Data;
    using Account for Account.Data;
    using SafeCastU256 for uint256;

    error AccountNotEligibleForAutoExchange(uint128 accountId, address quoteType);

    error CollateralAutoExchangeBreached(uint128 accountId, address collateralType);

    error ExceedsAutoExchangeLimit(uint256 maxAmountQuote, address quoteType);

    error WithinBubbleCoverageNotExhausted(uint128 accountId, address quoteType, address collateralType);

    error SameQuoteAndCollateralType(uint128 accountId, address quoteType);

    error ZeroAddressToken(uint128 accountId);

    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) internal {

        Account.Data storage account = Account.exists(accountId);

        if (!account.isEligibleForAutoExchange(quoteType)) {
            revert AccountNotEligibleForAutoExchange(accountId, quoteType);
        }

        if (!account.isWithinBubbleCoverageExhausted(quoteType, collateralType)) {
            revert WithinBubbleCoverageNotExhausted(accountId, quoteType, collateralType);
        }

        if (quoteType == collateralType) {
            revert SameQuoteAndCollateralType(accountId, quoteType);
        }

        if (quoteType == address(0) || collateralType == address(0)) {
            revert ZeroAddressToken(accountId);
        }

        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        Account.Data storage insuranceFundAccount = Account.exists(collateralPool.insuranceFundConfig.accountId);

        (
            uint256 collateralAmountToLiquidator,
            uint256 collateralAmountToIF,
            uint256 quoteAmount
        ) = account.calculateAvailableCollateralToAutoExchange(
            collateralType,
            quoteType,
            amountToAutoExchangeQuote
        );

        account.updateNetCollateralDeposits(
            quoteType,
            quoteAmount.toInt()
        );

        account.updateNetCollateralDeposits(
            collateralType,
            -(collateralAmountToLiquidator + collateralAmountToIF).toInt()
        );

        liquidatorAccount.updateNetCollateralDeposits(
            quoteType,
            -quoteAmount.toInt()
        );


        insuranceFundAccount.updateNetCollateralDeposits(
            collateralType,
            collateralAmountToIF.toInt()
        );

        liquidatorAccount.updateNetCollateralDeposits(
            collateralType,
            collateralAmountToLiquidator.toInt()
        );

        if (account.isEligibleForAutoExchange(collateralType)) {
            revert AccountNotEligibleForAutoExchange(accountId, collateralType);
        }

        liquidatorAccount.imCheck(address(0));

    }
}
