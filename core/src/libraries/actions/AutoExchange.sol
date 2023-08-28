/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "../../storage/Account.sol";
import "../AccountAutoExchange.sol";

/**
 * @title Library for executing liquidation logic.
 */
library AutoExchange {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using AccountAutoExchange for Account.Data;
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
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        CollateralPool.InsuranceFundConfig memory insuranceFundConfig = 
            Market.exists(account.firstMarketId).getCollateralPool().insuranceFundConfig;
        Account.Data storage insuranceFundAccount = Account.exists(
            insuranceFundConfig.accountId
        );

        bool eligibleForAutoExchange = account.isEligibleForAutoExchange(quoteType);
        if (!eligibleForAutoExchange) {
            revert AccountNotEligibleForAutoExchange(accountId);
        }

        uint256 maxExchangeableAmountQuote = getMaxAmountToExchangeQuote(accountId, collateralType, quoteType);
        if (amountToAutoExchangeQuote > maxExchangeableAmountQuote) {
            revert ExceedsAutoExchangeLimit(maxExchangeableAmountQuote, collateralType, quoteType);
        }

        // get collateral amount received by the liquidator
        uint128 collateralPoolId = account.getCollateralPool().id;
        uint256 amountToAutoExchangeCollateral = CollateralConfiguration.
            getAutoExchangeAmount(collateralPoolId, quoteType, collateralType, amountToAutoExchangeQuote);

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

    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address collateralType,
        address quoteType
    ) internal view returns (uint256 maxAmountQuote) {
        // todo: revisit
        return 0;
        
        // Account.Data storage account = Account.exists(accountId);

        // int256 quoteAccountValueInQuote = account.getAccountValueByCollateralType(quoteType);
        // if (quoteAccountValueInQuote > 0) {
        //     return 0;
        // }

        // maxAmountQuote = mulUDxUint(
        //     AutoExchangeConfiguration.load().autoExchangeRatio,
        //     (-quoteAccountValueInQuote).toUint()
        // );

        // uint256 accountCollateralAmountInCollateral = account.getCollateralBalance(collateralType);

        // CollateralConfiguration.Data storage quoteConfiguration = 
        //     CollateralConfiguration.exists(quoteType);
        // uint256 maxAmountQuoteInUSD = quoteConfiguration
        //     .getCollateralInUSD(maxAmountQuote);
        
        // uint256 accountCollateralAmountInUSD = CollateralConfiguration.exists(collateralType)
        //     .getCollateralInUSD(accountCollateralAmountInCollateral);

        // if (maxAmountQuoteInUSD > accountCollateralAmountInUSD) {
        //     maxAmountQuote = quoteConfiguration
        //         .getUSDInCollateral(accountCollateralAmountInUSD);
        // }
    }
}
