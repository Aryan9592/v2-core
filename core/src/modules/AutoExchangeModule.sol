/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {IAutoExchangeModule} from "../interfaces/IAutoExchangeModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";


/**
 * @title Module for auto-exchange, i.e. liquidations of collaterals to address exchange rate risk
 * @dev See IAutoExchangeModule
 */

contract AutoExchangeModule is IAutoExchangeModule {
    using Account for Account.Data;
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId, address quoteType) external view override returns (
        bool
    ) {
        return Account.exists(accountId).isEligibleForAutoExchange(quoteType);
    }
    
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address coveringToken,
        address autoExchangedToken
    ) external view returns (uint256 /* coveringAmount */, uint256 /* autoExchangedAmount */ ) {
        return Account.exists(accountId).getMaxAmountToExchangeQuote(
            coveringToken,
            autoExchangedToken
        );
    }
}
