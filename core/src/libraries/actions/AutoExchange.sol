/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {AccountAutoExchange} from "../account/AccountAutoExchange.sol";

/**
 * @title Library to trigger auto-exchange
 */
library AutoExchange {

    using AccountAutoExchange for Account.Data;

    error AccountNotEligibleForAutoExchange(uint128 accountId, address quoteType);

    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) internal {

        // grab the account and check its existance
        Account.Data storage account = Account.exists(accountId);

        if (!account.isEligibleForAutoExchange(quoteType)) {
            revert AccountNotEligibleForAutoExchange(accountId, quoteType);
        }




    }
}
