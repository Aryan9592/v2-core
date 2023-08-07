/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import "../storage/Account.sol";

/**
 * @title Object for tracking account margin requirements.
 */
library AccountMode {
    using Account for Account.Data;
    using SetUtil for SetUtil.AddressSet;

    error UnknwonAccountMode(bytes32 accountMode);

    /**
     * @notice Emitted when the account mode is switched.
     * @param accountId The id of the account.
     * @param accountMode The new mode of the account.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountModeUpdated(uint128 indexed accountId, bytes32 accountMode, uint256 blockTimestamp);

    function checkAccountMode(bytes32 accountMode) internal pure {
        if (accountMode == Account.SINGLE_TOKEN_MODE || accountMode == Account.MULTI_TOKEN_MODE) {
            return;
        }

        revert UnknwonAccountMode(accountMode);
    }
    
    function setAccountMode(Account.Data storage self, bytes32 accountMode) internal {
        checkAccountMode(accountMode);
        self.accountMode = accountMode;

        emit AccountModeUpdated(self.id, accountMode, block.timestamp);
    }

    function changeAccountMode(Account.Data storage self, bytes32 newAccountMode) internal {
        setAccountMode(self, newAccountMode);
    
        if (newAccountMode == Account.SINGLE_TOKEN_MODE) {
            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);
                self.imCheck(quoteToken);
            }
        }

        if (newAccountMode == Account.MULTI_TOKEN_MODE) {
            self.imCheck(address(0));
        }

        emit AccountModeUpdated(self.id, newAccountMode, block.timestamp);
    }
}
