/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {AccountAutoExchange} from "../account/AccountAutoExchange.sol";
import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/*
TODOs
    - consider introducing min amount of collateral to get in return (works similar to a limit price)
    - make sure re-entrancy is not possible with collateral transfers
*/


/**
 * @title Library to trigger auto-exchange
 */
library AutoExchange {

    using AccountAutoExchange for Account.Data;
    using Account for Account.Data;
    using SafeCastU256 for uint256;

    error AccountNotEligibleForAutoExchange(uint128 accountId, address quoteType);

    error ExceedsAutoExchangeLimit(uint256 maxAmountQuote, address quoteType);

    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) internal {

        Account.Data storage account = Account.exists(accountId);
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        if (!account.isEligibleForAutoExchange(quoteType)) {
            revert AccountNotEligibleForAutoExchange(accountId, quoteType);
        }

        (uint256 collateralAmount, uint256 quoteAmount) = account.calculateAvailableCollateralToAutoExchange(
            collateralType,
            quoteType,
            amountToAutoExchangeQuote
        );

        account.updateNetCollateralDeposits(
            quoteType,
            quoteAmount.toInt()
        );

        account.updateNetCollateralDeposits(
            collateralType,
            -collateralAmount.toInt()
        );

        liquidatorAccount.updateNetCollateralDeposits(
            quoteType,
            -quoteAmount.toInt()
        );

        liquidatorAccount.updateNetCollateralDeposits(
            collateralType,
            collateralAmount.toInt()
        );

    }
}
