/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


import "../storage/Account.sol";
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
    using CollateralConfiguration for CollateralConfiguration.Data;

    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId, address settlementType) external view override returns (
        bool isEligibleForAutoExchange
    ) {
        Account.Data storage account = Account.exists(accountId);
        return account.isEligibleForAutoExchange(settlementType);
    }

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchngeQuote,
        address collateralType,
        address settlementType
    ) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.Data storage account = Account.exists(accountId);
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);
        Account.Data storage insuranceFundAccount = Account.exists(999); // todo: get from collateral pool

        bool isEligibleForAutoExchange = 
            account.isEligibleForAutoExchange(settlementType);

        if (!isEligibleForAutoExchange) {
            revert AccountNotEligibleForAutoExchange(accountId);
        }

        uint256 maxExchangeableAmountQuote = getMaxAmountToExchangeQuote(accountId, collateralType, settlementType);
        require(amountToAutoExchngeQuote <= maxExchangeableAmountQuote, "Max auto-exchange"); //todo: custon error

        // get collateral amount received by the liquidator
        uint256 amountToAutoExchangeCollateral = 
            getExchangedCollateralAmount(amountToAutoExchngeQuote, collateralType, settlementType);

        // transfer settlement tokens from liquidator's account to liquidatable account
        liquidatorAccount.decreaseCollateralBalance(settlementType, amountToAutoExchngeQuote);
        // subtract insurance fund fee from settlement repayment
        uint256 insuranceFundFeeQuote = mulUDxUint(
            AutoExchangeConfiguration.load().autoExchangeRatio,
            amountToAutoExchngeQuote
        );
        insuranceFundAccount.increaseCollateralBalance(settlementType, insuranceFundFeeQuote);
        account.increaseCollateralBalance(settlementType, amountToAutoExchngeQuote - insuranceFundFeeQuote);

        // transfer discounted collateral tokens from liquidatable account to liquidator's account
        account.decreaseCollateralBalance(collateralType, amountToAutoExchangeCollateral);
        liquidatorAccount.increaseCollateralBalance(collateralType, amountToAutoExchangeCollateral);
    }

    /// @dev Returns the maximum amount that can be exchaged, represented in settlement token
    // todo: get liquidation ratio from config
    // todo: apply liquidation ratio before or after comparison?
    // todo: do we consider pnl as "collateral" that can be exchange?
        // can use only avaiable collateral, ensuring discount doesn't break the IM invariant
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address collateralType,
        address settlementType
    ) public returns (uint256 maxAmountQuote) {
        Account.Data storage account = Account.exists(accountId);

        int256 accountValueInSettlementTokenQuote = account.getAccountValueByCollateralType(settlementType);
        if (accountValueInSettlementTokenQuote > 0) {
            return 0;
        }

        maxAmountQuote = mulUDxUint(
            AutoExchangeConfiguration.load().autoExchangeRatio,
            (-accountValueInSettlementTokenQuote).toUint()
        );

        uint256 accountCollateralAmountCollateral = account.getCollateralBalance(collateralType);

        CollateralConfiguration.Data storage settlementConfiguration = 
            CollateralConfiguration.load(settlementType);
        uint256 accountValueInSettlementToken_U = settlementConfiguration
            .getCollateralInUSD(maxAmountQuote);
        
        
        uint256 accountCollateralAmount_U = CollateralConfiguration.load(collateralType)
            .getCollateralInUSD(accountCollateralAmountCollateral);

        if (accountValueInSettlementToken_U > accountCollateralAmount_U) {
            maxAmountQuote = settlementConfiguration
                .getUSDInCollateral(accountCollateralAmount_U);
        }
    }

    // todo: find a better name for this function
    function getExchangedCollateralAmount(
        uint256 amountQuote,
        address collateralType,
        address settlementType
    ) public returns (uint256 discountedAmountCollateral) {
        uint256 amountToAutoExchange_U = CollateralConfiguration.load(settlementType)
            .getCollateralInUSD(amountQuote);
        uint256 amountToAutoExchngeQuote = CollateralConfiguration.load(collateralType)
            .getUSDInCollateral(amountToAutoExchange_U);

        // apply discount
        discountedAmountCollateral = divUintUDx(
            amountToAutoExchngeQuote, 
            UNIT.sub(CollateralConfiguration.load(collateralType).config.autoExchangeDiscount)
        );
    }

}
