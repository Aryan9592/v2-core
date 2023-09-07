/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../../interfaces/external/IMarketManager.sol";

/**
 * @title Library for matched orders logic.
 */
library MatchedOrders {
    using Account for Account.Data;
    using AccountExposure for Account.Data;

    function matchedOrder(
        uint128 accountId,
        uint128 marketId,
        IMarketManager marketManager,
        bytes calldata inputs
    ) internal returns (
        bytes memory matchResult,
        uint128 counterPartyAccountId,
        uint256 initialCounterPartyMarketExposure
    ) {
        bytes[] memory orderInputs;
        assembly {
            counterPartyAccountId := calldataload(inputs.offset)
            orderInputs := calldataload(add(inputs.offset, 0x20))
        }

        // verify counterparty account & access
        Account.Data storage counterPartyAccount = 
            Account.loadAccountAndValidatePermission(counterPartyAccountId, Account.ADMIN_PERMISSION, msg.sender);
        counterPartyAccount.ensureEnabledCollateralPool();
        
        // execute orders
        initialCounterPartyMarketExposure = counterPartyAccount.getTotalAbsoluteMarketExposure(marketId);

        (bytes memory result,) = 
            marketManager.executeTakerOrder(accountId, marketId, orderInputs[0]);

        (bytes memory counterPartyResult,) = 
                marketManager.executeTakerOrder(counterPartyAccountId, marketId, orderInputs[1]);

        matchResult = abi.encode(result, counterPartyResult);
    }
}
