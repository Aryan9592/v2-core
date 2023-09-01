/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {Market} from "../../storage/Market.sol";

import {SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Library for executing liquidation logic.
 */
library AutoExchange {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using Market for Market.Data;
    using SafeCastI256 for int256;

    error ExceedsAutoExchangeLimit(uint256 maxAmountQuote, address collateralType, address quoteType);
    /**
     * @dev Thrown when an account is not eligible for auto-exchange
     */
    error AccountNotEligibleForAutoExchange(uint128 accountId);


    // todo: consider adding a price limit 
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) internal {

        Account.Data storage account = Account.exists(accountId);

        bool eligibleForAutoExchange = account.isEligibleForAutoExchange(quoteType);
        if (!eligibleForAutoExchange) {
            revert AccountNotEligibleForAutoExchange(accountId);
        }

        (uint256 amountToAutoExchangeCollateral, uint256 maxExchangeableAmountQuote) = 
            account.getMaxAmountToExchangeQuote(collateralType, quoteType);

        if (amountToAutoExchangeQuote > maxExchangeableAmountQuote) {
            revert ExceedsAutoExchangeLimit(maxExchangeableAmountQuote, collateralType, quoteType);
        }

        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        CollateralPool.InsuranceFundConfig memory insuranceFundConfig = 
            Market.exists(account.firstMarketId).getCollateralPool().insuranceFundConfig;
        Account.Data storage insuranceFundAccount = Account.exists(
            insuranceFundConfig.accountId
        );

        // transfer quote tokens from liquidator's account to liquidatable account
        liquidatorAccount.decreaseCollateralBalance(quoteType, amountToAutoExchangeQuote);
        // subtract insurance fund fee from quote repayment
        uint256 insuranceFundFeeQuote = mulUDxUint(
            insuranceFundConfig.autoExchangeFee,
            amountToAutoExchangeQuote
        );
        insuranceFundAccount.increaseCollateralBalance(quoteType, insuranceFundFeeQuote);
        account.increaseCollateralBalance(quoteType, amountToAutoExchangeQuote - insuranceFundFeeQuote);

        // transfer discounted collateral tokens from liquidatable account to liquidator's account
        account.decreaseCollateralBalance(collateralType, amountToAutoExchangeCollateral);
        liquidatorAccount.increaseCollateralBalance(collateralType, amountToAutoExchangeCollateral);
    }
}
