/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { AccountPermissions, MarginInfo } from "../libraries/DataTypes.sol";

/**
 * @title Account Manager Interface.
 * @notice Manages the system's account token NFT. Every user will need to register an account before being able to interact with
 * the protocol..
 */
interface IAccountModule {
    /**
     * @notice Thrown when the account interacting with the system is expected to be the associated account token, but is not.
     */
    error OnlyAccountTokenProxy(address origin);

    /**
     * @notice Thrown when an account attempts to renounce a permission that it didn't have.
     */
    error PermissionNotGranted(uint128 accountId, bytes32 permission, address user);

    /**
     * @notice Returns an array of `AccountPermission` for the provided `accountId`.
     * @param accountId The id of the account whose permissions are being retrieved.
     * @return accountPerms An array of AccountPermission objects describing the permissions granted to the account.
     */
    function getAccountPermissions(uint128 accountId)
        external
        view
        returns (AccountPermissions[] memory accountPerms);

    /**
     * @notice Mints an account token with id `requestedAccountId` to `msg.sender`.
     * @param requestedAccountId The id requested for the account being created. Reverts if id already exists.
     * Requirements:
     *
     * - `requestedAccountId` must not already be minted.
     *
     * Emits a {AccountCreated} event.
     */
    function createAccount(uint128 requestedAccountId, address accountOwner) external;

    /**
     * @notice Called by AccountTokenModule to notify the system when the account token is transferred.
     * @dev Resets user permissions and assigns ownership of the account token to the new holder.
     * @param to The new holder of the account NFT.
     * @param accountId The id of the account that was just transferred.
     *
     * Requirements:
     *
     * - `msg.sender` must be the account token.
     */
    function notifyAccountTransfer(address to, uint128 accountId) external;

    /**
     * @notice Grants `permission` to `user` for account `accountId`.
     * @param accountId The id of the account that granted the permission.
     * @param permission The bytes32 identifier of the permission.
     * @param user The target address that received the permission.
     *
     * Requirements:
     *
     * - `msg.sender` must own the account token with ID `accountId` or have the "admin" permission.
     *
     * Emits a {AccountPermissionGranted} event.
     */
    function grantPermission(uint128 accountId, bytes32 permission, address user) external;

    /**
     * @notice Revokes `permission` from `user` for account `accountId`.
     * @param accountId The id of the account that revoked the permission.
     * @param permission The bytes32 identifier of the permission.
     * @param user The target address that no longer has the permission.
     *
     * Requirements:
     *
     * - `msg.sender` must own the account token with ID `accountId` or have the "admin" permission.
     *
     * Emits a {AccountPermissionRevoked} event.
     */
    function revokePermission(uint128 accountId, bytes32 permission, address user) external;

    /**
     * @notice Revokes `permission` from `msg.sender` for account `accountId`.
     * @param accountId The id of the account whose permission was renounced.
     * @param permission The bytes32 identifier of the permission.
     *
     * Emits a {AccountPermissionRevoked} event.
     */
    function renouncePermission(uint128 accountId, bytes32 permission) external;

    /**
     * @notice Returns `true` if `user` has been granted `permission` for account `accountId`.
     * @param accountId The id of the account whose permission is being queried.
     * @param permission The bytes32 identifier of the permission.
     * @param user The target address whose permission is being queried.
     * @return hasPermission A boolean with the response of the query.
     */
    function hasPermission(uint128 accountId, bytes32 permission, address user)
        external
        view
        returns (bool hasPermission);

    /**
     * @notice Returns the address for the account token NFT that represents ownership of a given Reya account.
     * @return accountNftToken The address of the account token NFT contract.
     */
    function getAccountTokenAddress() external view returns (address accountNftToken);

    /**
     * @notice Returns the address that owns a given account, as recorded by the protocol.
     * @param accountId The account id whose owner is being retrieved.
     * @return owner The owner of the given account id.
     */
    function getAccountOwner(uint128 accountId) external view returns (address owner);

    /**
     * @notice Returns `true` if `target` is authorized to `permission` for account `accountId`.
     * @param accountId The id of the account whose permission is being queried.
     * @param permission The bytes32 identifier of the permission.
     * @param target The target address whose permission is being queried.
     * @return isAuthorized A boolean with the response of the query. If true, then the target is authorized.
     */
    function isAuthorized(uint128 accountId, bytes32 permission, address target)
        external
        view
        returns (bool isAuthorized);

    /**
     * @notice Get the initial and liquidation margin requirements and highest unrealized loss
     * (if maker positions were to be filled) along with the flags that specify if the initial or liquidation margin
     * requirements are satisfied.
     * @param accountId The id of the account that is being checked
     * @param collateralType The collateral type for which the margin requirements are checked,
     * where the collateral type is the centre of a given collateral bubble
     * @return Margin requirement information object
     */
    function getMarginInfoByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        returns (MarginInfo memory);
}
