/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {IAutoExchangeModule} from "../interfaces/IAutoExchangeModule.sol";
import {AccountAutoExchange} from "../libraries/account/AccountAutoExchange.sol";
import {AutoExchange} from "../libraries/actions/AutoExchange.sol";

/**
 * @title Module for auto-exchange, i.e. liquidations of collaterals to address exchange rate risk
 * @dev See IAutoExchangeModule
 */

contract AutoExchangeModule is IAutoExchangeModule {
    using Account for Account.Data;
    using AccountAutoExchange for Account.Data;
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId, address token) external view override returns (
        bool
    ) {
        Account.Data storage account = Account.exists(accountId);
        return account.isEligibleForAutoExchange(token);
    }
    
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) external {
        AutoExchange.triggerAutoExchange(
            accountId,
            liquidatorAccountId,
            amountToAutoExchangeQuote,
            collateralType,
            quoteType
        );
    }
}
