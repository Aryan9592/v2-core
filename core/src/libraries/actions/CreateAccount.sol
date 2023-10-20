/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "@voltz-protocol/util-modules/src/storage/AssociatedSystem.sol";

import { BlendedADLLongId, BlendedADLShortId } from "../Constants.sol";

import "../../storage/Account.sol";
import "../../storage/AccessPassConfiguration.sol";
import "../../interfaces/IAccountTokenModule.sol";
import "../../interfaces/external/IAccessPassNFT.sol";

/**
 * @title Library for account creation logic.
 */
library CreateAccount {
    using Account for Account.Data;

    bytes32 private constant _ACCOUNT_SYSTEM = "accountNFT";

    /**
     * @notice Thrown when attempting to create account without owning an access pass
     */
    error OnlyAccessPassOwner(uint128 requestedAccountId, address accountOwner);

    /**
    * @notice Thrown when attempting to create account with reserved account id
     */
    error ReservedAccountId(uint128 requestedAccountId);

    /**
     * @notice Emitted when an account token with id `accountId` is minted to `owner`.
     * @param accountId The id of the account.
     * @param owner The address that owns the created account.
     * @param trigger The address that triggered account creation.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountCreated(uint128 indexed accountId, address indexed owner, address indexed trigger, uint256 blockTimestamp);

    function createAccount(uint128 requestedAccountId, address accountOwner) internal {
        // todo: the comment below is confusing, since the account module exposes this function, not just the
        // execution module, is the intention to remove this function from the account module?
        /*
            Note, anyone can create an account for any accountOwner as long as the accountOwner owns the account pass nft.
            This feature will only be available to the Executor Module which will need to make sure accountOwner == msg.sender
        */
        FeatureFlagSupport.ensureCreateAccountAccess();

        if (requestedAccountId == BlendedADLLongId || requestedAccountId == BlendedADLShortId) {
            revert ReservedAccountId(requestedAccountId);
        }

        address accessPassNFTAddress = AccessPassConfiguration.exists().accessPassNFTAddress;

        uint256 ownerAccessPassBalance = IAccessPassNFT(accessPassNFTAddress).balanceOf(accountOwner);
        if (ownerAccessPassBalance == 0) {
            revert OnlyAccessPassOwner(requestedAccountId, accountOwner);
        }

        IAccountTokenModule accountTokenModule = IAccountTokenModule(getAccountTokenAddress());
        accountTokenModule.safeMint(accountOwner, requestedAccountId, "");

        Account.create(requestedAccountId, accountOwner);
        
        emit AccountCreated(requestedAccountId, accountOwner, msg.sender, block.timestamp);
    }

    function getAccountTokenAddress() internal view returns (address) {
        return AssociatedSystem.load(_ACCOUNT_SYSTEM).proxy;
    }
}
