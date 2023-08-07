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
    function triggerAutoExchange(uint128 autoExchangeAccountId, uint128 autoExchangeTriggerAccountId,
    uint256 amountToAutoExchange, address collateralType) external
    override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.Data storage account = Account.exists(autoExchangeAccountId);

        if (!account.isMultiToken) {
            // todo: move this logic into account library (or inside isEligibleForAutoExchange) - Costin
            revert AccountIsSingleTokenNoExposureToExchangeRateRisk(autoExchangeAccountId);
        }

        bool isEligibleForAutoExchange = account.isEligibleForAutoExchange();

        if (!isEligibleForAutoExchange) {
            revert AccountNotEligibleForAutoExchange(autoExchangeAccountId);
        }

        // todo: needs the remaining implementation

    }

}
