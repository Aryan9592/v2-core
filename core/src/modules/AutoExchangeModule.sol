/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


import "../storage/Account.sol";
import "../interfaces/IAutoExchangeModule.sol";
import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";



// todo: consider forcing auto-exchange at settlement for maturity-based markets (AB)
/**
 * @title Module for auto-exchange, i.e. liquidations of collaterals to address exchange rate risk
 * @dev See IAutoExchangeModule
 */

contract AutoExchangeModule is IAutoExchangeModule {

    using Account for Account.Data;

    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId) external view override returns (
        bool isEligibleForAutoExchange
    ) {
        Account.Data storage account = Account.exists(accountId);
        return account.isEligibleForAutoExchange();
    }

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchange_S,
        address collateralType,
        address settlemetType
    ) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.Data storage account = Account.exists(accountId);

        bool isEligibleForAutoExchange = 
            account.isEligibleForAutoExchange(accountId, settlemetType);

        if (!isEligibleForAutoExchange) {
            revert AccountNotEligibleForAutoExchange(accountId);
        }

        uint256 maxExchangeableAmount_S = getMaxAmountToExchange_S(account, collateralType);
        require(amountToAutoExchange_S <= maxExchangeableAmount_S, "Max auto-exchange"); //todo: custon error

        // get collateral amount received by the liquidator
        uint256 amountToAutoExchange_C = 
            getExchangedCollateralAmount(amountToAutoExchange_S, collateralType, settlemetType);

        // transfer settlement tokens from liquidator's account to liquidatable account
        liquidatorAccount.decreaseCollateralBalance(settlemetType, amountToAutoExchange_S);
        // subtact insurance fund fee from settlement repayment
        uint256 insuranceFundFee_S = amountToAutoExchange_S.mul(insuranceFundFee);
        insuranceFundAccount.increaseCollateralBalance(settlemetType, insuranceFundFee_S);
        account.increaseCollateralBalance(settlemetType, amountToAutoExchange_S - insuranceFundFee_S);

        // transfer discounted collateral tokens from liquidatable account to liquidator's account
        account.decreaseCollateralBalance(collateralType, amountToAutoExchange_C);
        liquidatorAccount.increaseCollateralBalance(collateralType, amountToAutoExchange_C);
    }

    /// @dev Returns the maximum amount that can be exchaged, represented in settlement token
    // todo: get liquidation ratio from config
    // todo: apply liquidation ratio before or after comparison?
    // todo: do we consider pnl as "collateral" that can be exchange?
        // can use only avaiable collateral, ensuring discount doesn't break the IM invariant
    function getMaxAmountToExchange_S(
        Account.Data storage account,
        address collateralType,
        address settlementType
    ) public returns (uint256) {
        // get collateral + realized + unrealized Pnl in settlement token
        int256 accountValueInSettlementToken_S = account.getAccountValueInToken(settlementType);
        if (accountValueInSettlementToken_S > 0) {
            return 0;
        }

        int256 accountCollateralAmount_C = account.getCollateralBalance(collateralType);

        CollateralConfiguration.Data memory settlementConfiguration = 
            CollateralConfiguration.load(settlementToken);
        int256 accountValueInSettlementToken_U = settlementConfiguration
            .getCollateralInUSD(accountValueInSettlementToken_S * liquidationRatio);
        
        
        int256 accountCollateralAmount_U = CollateralConfiguration.load(collateralType)
            .getCollateralInUSD(accountCollateralAmount_C);

        if (accountValueInSettlementToken_U > accountCollateralAmount_U) {
            return settlementConfiguration.getUSDInCollateral(accountCollateralAmount_U);
        }

        return accountValueInSettlementToken_S * liquidationRatio;
    }

    function getExchangedCollateralAmount(
        uint265 amount_S,
        address collateralType,
        address settlementType
    ) public returns (uint256 discountedAmount_C) {
        int256 amountToAutoExchange_U = CollateralConfiguration.load(settlementType)
            .getCollateralInUSD(amountToAutoExchange_S);
        int256 amountToAutoExchange_S = CollateralConfiguration.load(collateralType)
            .getUSDInCollateral(amountToAutoExchange_U);

        // apply discount
        discountedAmount_C = divUintUDx(
            amountToAutoExchange_S, 
            ONE.sub(CollateralConfiguration.load(collateralType).autoExchangeDiscount)
        );
    }

}
