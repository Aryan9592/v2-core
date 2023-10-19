/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IAccountTokenModule} from "../interfaces/IAccountTokenModule.sol";
import {IAccountModule} from "../interfaces/IAccountModule.sol";
import {Account} from "../storage/Account.sol";
import {AccessPassConfiguration} from "../storage/AccessPassConfiguration.sol";
import {IAccessPassNFT} from "../interfaces/external/IAccessPassNFT.sol";
import "../libraries/actions/CreateAccount.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import {AssociatedSystem} from "@voltz-protocol/util-modules/src/storage/AssociatedSystem.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {Signature} from "../storage/Signature.sol";

/**
 * @title Account Manager.
 * @dev See IAccountModule.
 */
contract AccountModule is IAccountModule {
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.Bytes32Set;
    using Account for Account.Data;

    bytes32 internal constant GRANT_PERMISSION_TYPEHASH =
    keccak256('GrantPermissionBySig(uin128 accountId, bytes32 permission, address user, uint256 nonce,uint256 deadline)');

    bytes32 private constant _ACCOUNT_SYSTEM = "accountNFT";
    /**
     * @inheritdoc IAccountModule
     */
    function getAccountTokenAddress() public view override returns (address) {
        return CreateAccount.getAccountTokenAddress();
    }

    /**
     * @inheritdoc IAccountModule
     */
    function getAccountPermissions(uint128 accountId)
        external
        view
        returns (AccountPermissions[] memory accountPerms)
    {
        Account.RBAC storage accountRbac = Account.exists(accountId).rbac;

        uint256 allPermissionsLength = accountRbac.permissionAddresses.length();
        accountPerms = new AccountPermissions[](allPermissionsLength);
        for (uint256 i = 1; i <= allPermissionsLength; i++) {
            address permissionAddress = accountRbac.permissionAddresses.valueAt(i);
            accountPerms[i - 1] = AccountPermissions({
                user: permissionAddress,
                permissions: accountRbac.permissions[permissionAddress].values()
            });
        }
    }

    /**
     * @inheritdoc IAccountModule
     */
    function createAccount(uint128 requestedAccountId, address accountOwner) external override {
        CreateAccount.createAccount(requestedAccountId, accountOwner);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function notifyAccountTransfer(address to, uint128 accountId) external override {
        /*
            Note, denying account transfers also blocks Margin Account token transfers.
        */
        FeatureFlagSupport.ensureGlobalAccess();
        FeatureFlagSupport.ensureNotifyAccountTransferAccess();
        _onlyAccountToken();

        Account.Data storage account = Account.exists(accountId);

        address[] memory permissionedAddresses = account.rbac.permissionAddresses.values();
        for (uint256 i = 0; i < permissionedAddresses.length; i++) {
            account.revokeAllPermissions(permissionedAddresses[i]);
        }

        account.setOwner(to);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function hasPermission(uint128 accountId, bytes32 permission, address user) public view override returns (bool) {
        return Account.exists(accountId).hasPermission(permission, user);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function getAccountOwner(uint128 accountId) public view returns (address) {
        return Account.exists(accountId).rbac.owner;
    }

    /**
     * @inheritdoc IAccountModule
     */
    function isAuthorized(uint128 accountId, bytes32 permission, address user) public view override returns (bool) {
        // todo: the interface uses target instead of user, consider aligning
        return Account.exists(accountId).authorized(permission, user);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function grantPermission(uint128 accountId, bytes32 permission, address user) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account = Account.loadAccountAndValidateOwnership(accountId, msg.sender);

        account.grantPermission(permission, user);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function grantPermissionBySig(
        uint128 accountId,
        bytes32 permission,
        address user,
        Signature.EIP712Signature calldata sig
    ) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account = Account.exists(accountId);
        address accountOwner = account.rbac.owner;
        uint256 incrementedNonce = Signature.incrementSigNonce(accountOwner);
        unchecked {
            Signature.validateRecoveredAddress(
                Signature.calculateDigest(
                    keccak256(
                        abi.encode(
                            GRANT_PERMISSION_TYPEHASH,
                            accountId,
                            permission,
                            user,
                            incrementedNonce,
                            sig.deadline
                        )
                    )
                ),
                accountOwner,
                sig
            );
        }
        account.grantPermission(permission, user);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function revokePermission(uint128 accountId, bytes32 permission, address user) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account = Account.loadAccountAndValidateOwnership(accountId, msg.sender);

        account.revokePermission(permission, user);
    }

    /**
     * @inheritdoc IAccountModule
     */
    function renouncePermission(uint128 accountId, bytes32 permission) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        if (!Account.exists(accountId).hasPermission(permission, msg.sender)) {
            revert PermissionNotGranted(accountId, permission, msg.sender);
        }

        Account.exists(accountId).revokePermission(permission, msg.sender);
    }

    /**
     * @dev Reverts if the caller is not the account token managed by this module.
     */
    function _onlyAccountToken() internal view {
        if (msg.sender != address(getAccountTokenAddress())) {
            revert OnlyAccountTokenProxy(msg.sender);
        }
    }

    /**
     * @inheritdoc IAccountModule
     */
    function getMarginInfoByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        override 
        returns (Account.MarginInfo memory) 
    {
        return Account.exists(accountId).getMarginInfoByBubble(collateralType);
    }
}
