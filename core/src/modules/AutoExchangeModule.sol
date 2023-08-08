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

        (uint256 amountToAutoExchange_C, uint256 insuranceFundFee_C) = toUSD(amountToAutoExchange_S)
            .toCollateralAmount_usingDiscountTwap();

        // transfer settlement tokens from liquidator's account to liquidatable account
        liquidatorAccount.decreaseCollateralBalance(settlemetType, amountToAutoExchange_S);
        account.increaseCollateralBalance(settlemetType, amountToAutoExchange_S);

        // transfer discounted collateral tokens from liquidatable account to liquidator's account
        account.decreaseCollateralBalance(collateralType, amountToAutoExchange_C);
        liquidatorAccount.increaseCollateralBalance(collateralType, amountToAutoExchange_C);

        // todo: % to insurance fund
        Account.exists(insuranceFund).increaseCollateralBalance(insuranceFundFee_C);
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

        int256 accountValueInSettlementToken_U = toUSD(accountValueInSettlementToken_S * liquidationRatio, settlementToken);
        int256 accountCollateralAmount_U = toUSD(accountCollateralAmount_C, collateralType);

        if (accountValueInSettlementToken_U > accountCollateralAmount_U) {
            return toSettlementToken(accountCollateralAmount_U);
        }

        return accountValueInSettlementToken_S * liquidationRatio;
    }

}
