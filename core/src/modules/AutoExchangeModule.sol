/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


import "../storage/Account.sol";
import "../libraries/AccountAutoExchange.sol";
import "../interfaces/IAutoExchangeModule.sol";
import "../storage/AutoExchangeConfiguration.sol";
import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UNIT } from "@prb/math/UD60x18.sol";


// todo: consider forcing auto-exchange at settlement for maturity-based markets (AB)
/**
 * @title Module for auto-exchange, i.e. liquidations of collaterals to address exchange rate risk
 * @dev See IAutoExchangeModule
 */

contract AutoExchangeModule is IAutoExchangeModule {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using Account for Account.Data;
    using AccountAutoExchange for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Market for Market.Data;

    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    error ExceedsAutoExchangeLimit(uint256 maxAmountQuote, address collateralType, address quoteType);

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId, address quoteType) external view override returns (
        bool
    ) {
        Account.Data storage account = Account.exists(accountId);
        return account.isEligibleForAutoExchange(quoteType);
    }

    /**
     * @inheritdoc IAutoExchangeModule
     */
    // todo: consider adding a price limit 
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);

        Account.Data storage account = Account.exists(accountId);
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        CollateralPool.InsuranceFundConfig memory insuranceFundConfig = 
            Market.load(account.firstMarketId).getCollateralPool().insuranceFundConfig;
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
        uint256 amountToAutoExchangeCollateral = CollateralConfiguration.load(collateralType).
            getCollateralAInCollateralBWithDiscount(amountToAutoExchangeQuote, quoteType);

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
    
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address collateralType,
        address quoteType
    ) public view returns (uint256 maxAmountQuote) {
        Account.Data storage account = Account.exists(accountId);

        int256 quoteAccountValueInQuote = account.getAccountValueByCollateralType(quoteType);
        if (quoteAccountValueInQuote > 0) {
            return 0;
        }

        maxAmountQuote = mulUDxUint(
            AutoExchangeConfiguration.load().autoExchangeRatio,
            (-quoteAccountValueInQuote).toUint()
        );

        uint256 accountCollateralAmountInCollateral = account.getCollateralBalance(collateralType);

        CollateralConfiguration.Data storage quoteConfiguration = 
            CollateralConfiguration.load(quoteType);
        uint256 maxAmountQuoteInUSD = quoteConfiguration
            .getCollateralInUSD(maxAmountQuote);
        
        
        uint256 accountCollateralAmountInUSD = CollateralConfiguration.load(collateralType)
            .getCollateralInUSD(accountCollateralAmountInCollateral);

        if (maxAmountQuoteInUSD > accountCollateralAmountInUSD) {
            maxAmountQuote = quoteConfiguration
                .getUSDInCollateral(accountCollateralAmountInUSD);
        }
    }

}
