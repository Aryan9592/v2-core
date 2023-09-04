/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/errors/AddressError.sol";

import "../../storage/Account.sol";

/**
 * @title Object for tracking an accounts permissions (role based access control).
 */

library AccountRBAC {
    using Account for Account.Data;
    using SetUtil for SetUtil.Bytes32Set;
    using SetUtil for SetUtil.AddressSet;

    /**
     * @dev Thrown when a permission specified by a user does not exist or is invalid.
     */
    error InvalidPermission(bytes32 permission);

    /**
     * @notice Emitted when an account token with id `accountId` is transferred to `newOwner`.
     * @param accountId The id of the account.
     * @param newOwner The address of the new owner.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountOwnerUpdated(
        uint128 indexed accountId, 
        address indexed newOwner,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when `user` is granted `permission` by `sender` for account `accountId`.
     * @param accountId The id of the account that granted the permission.
     * @param permission The bytes32 identifier of the permission.
     * @param user The target address to whom the permission was granted.
     * @param sender The Address that granted the permission.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountPermissionGranted(
        uint128 indexed accountId,
        bytes32 indexed permission,
        address indexed user,
        address sender,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when `user` has `permission` renounced or revoked by `sender` for account `accountId`.
     * @param accountId The id of the account that has had the permission revoked.
     * @param permission The bytes32 identifier of the permission.
     * @param user The target address for which the permission was revoked.
     * @param sender The address that revoked the permission.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountPermissionRevoked(
        uint128 indexed accountId,
        bytes32 indexed permission,
        address indexed user,
        address sender,
        uint256 blockTimestamp
    );

    /**
     * @dev Sets the owner of the account.
     */
    function setOwner(Account.Data storage self, address owner) internal {
        self.rbac.owner = owner;

        emit AccountOwnerUpdated(self.id, owner, block.timestamp);
    }

    /**
     * @dev Reverts if the specified permission is unknown to the account RBAC system.
     */
    function checkPermissionIsValid(bytes32 permission) internal pure {
        if (permission != Account.ADMIN_PERMISSION) {
            revert InvalidPermission(permission);
        }
    }

    /**
     * @dev Grants a particular permission to the specified target address.
     */
    function grantPermission(Account.Data storage self, bytes32 permission, address target) internal {
        if (target == address(0)) {
            revert AddressError.ZeroAddress();
        }

        checkPermissionIsValid(permission);

        if (!self.rbac.permissionAddresses.contains(target)) {
            self.rbac.permissionAddresses.add(target);
        }

        self.rbac.permissions[target].add(permission);

        emit AccountPermissionGranted(self.id, permission, target, msg.sender, block.timestamp);
    }

    /**
     * @dev Revokes a particular permission from the specified target address.
     */
    function revokePermission(Account.Data storage self, bytes32 permission, address target) internal {
        checkPermissionIsValid(permission);

        self.rbac.permissions[target].remove(permission);

        if (self.rbac.permissions[target].length() == 0) {
            self.rbac.permissionAddresses.remove(target);
        }

        emit AccountPermissionRevoked(self.id, permission, target, msg.sender, block.timestamp);
    }

    /**
     * @dev Revokes all permissions for the specified target address.
     * @notice only removes permissions for the given address, not for the entire account
     */
    function revokeAllPermissions(Account.Data storage self, address target) internal {
        bytes32[] memory permissions = self.rbac.permissions[target].values();

        if (permissions.length == 0) {
            return;
        }

        for (uint256 i = 0; i < permissions.length; i++) {
            self.rbac.permissions[target].remove(permissions[i]);

            emit AccountPermissionRevoked(self.id, permissions[i], target, msg.sender, block.timestamp);
        }

        self.rbac.permissionAddresses.remove(target);
    }

    /**
     * @dev Returns wether the specified address has the given permission.
     */
    function hasPermission(Account.Data storage self, bytes32 permission, address target) internal view returns (bool) {
        checkPermissionIsValid(permission);

        return target != address(0) && self.rbac.permissions[target].contains(permission);
    }

    /**
     * @dev Returns wether the specified target address has the given permission, or has the high level admin permission.
     */
    function authorized(Account.Data storage self, bytes32 permission, address target) internal view returns (bool) {
        checkPermissionIsValid(permission);

        return (
            (target == self.rbac.owner) || 
            hasPermission(self, Account.ADMIN_PERMISSION, target) || 
            hasPermission(self, permission, target)
        );
    }
}
