/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IMarketManager} from "../../interfaces/external/IMarketManager.sol";
import {Account} from "../../storage/Account.sol";
import {AccountExposure} from "../account/AccountExposure.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Library for matched orders logic.
 */
library MatchedOrders {
    using Account for Account.Data;
    using AccountExposure for Account.Data;
    using SafeCastU256 for uint256;

    function matchedOrder(
        uint128 accountId,
        uint128 marketId,
        IMarketManager marketManager,
        bytes calldata inputs
    ) internal returns (
        bytes memory result,
        bytes memory counterPartyResult,
        uint128 counterPartyAccountId
    ) {
        bytes[] memory orderInputs;
        assembly {
            counterPartyAccountId := calldataload(inputs.offset)
            orderInputs := calldataload(add(inputs.offset, 0x20))
        }

        // verify counterparty account & access
        Account.loadAccountAndValidatePermission(counterPartyAccountId, Account.ADMIN_PERMISSION, msg.sender);

        (result,) = 
            marketManager.executeTakerOrder(accountId, marketId, orderInputs[0]);

        (counterPartyResult,) = 
                marketManager.executeTakerOrder(counterPartyAccountId, marketId, orderInputs[1]);
    }
}
