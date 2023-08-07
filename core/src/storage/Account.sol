/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import "./Market.sol";

import "../libraries/AccountActiveMarket.sol";
import "../libraries/AccountCollateral.sol";
import "../libraries/AccountExposure.sol";
import "../libraries/AccountMode.sol";
import "../libraries/AccountRBAC.sol";


/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using Account for Account.Data;
    using Market for Market.Data;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;

    /**
     * @dev All account permissions used by the system
     * need to be hardcoded here.
     */
    bytes32 internal constant ADMIN_PERMISSION = "ADMIN";

    /**
     * @dev All account modes used by the system
     * need to be hardcoded here.
     */
    bytes32 constant public SINGLE_TOKEN_MODE = "SINGLE_TOKEN_MODE";
    bytes32 constant public MULTI_TOKEN_MODE = "MULTI_TOKEN_MODE";

    /**
     * @dev Thrown when the given target address does not own the given account.
     */
    error PermissionDenied(uint128 accountId, address target);

    /**
     * @dev Thrown when a given single-token account's account's total value is below the initial margin requirement
     * + the highest unrealized loss
     */
    error AccountBelowIM(uint128 accountId, address collateralType, MarginRequirement marginRequirements);

    /**
     * @dev Thrown when an account cannot be found.
     */
    error AccountNotFound(uint128 accountId);

    struct MarginRequirement {
        bool isIMSatisfied;
        bool isLMSatisfied;
        uint256 initialMarginRequirement;
        uint256 liquidationMarginRequirement;
        uint256 highestUnrealizedLoss;
        uint256 availableCollateralBalance;
        address collateralType;
    }

    struct MarketExposure {
        int256 annualizedNotional;
        // note, in context of dated irs with the current accounting logic it also includes accruedInterest
        uint256 unrealizedLoss;
    }

    struct MakerMarketExposure {
        MarketExposure lower;
        MarketExposure upper;
    }

    struct RBAC {
        /**
         * @dev The owner of the account
         */
        address owner;
        /**
         * @dev Set of permissions for each address enabled by the account.
         */
        mapping(address => SetUtil.Bytes32Set) permissions;
        /**
         * @dev Array of addresses that this account has given permissions to.
         */
        SetUtil.AddressSet permissionAddresses;
    }

    struct Data {
        /**
         * @dev Numeric identifier for the account. Must be unique.
         * @dev There cannot be an account with id zero (See ERC721._mint()).
         */
        uint128 id;
    
        /**
         * @dev Role based access control data for the account.
         */
        RBAC rbac;
    
        /**
         * @dev Address set of collaterals that are being used in the protocols by this account.
         */
        mapping(address => uint256) collateralBalances;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeCollaterals;
    
        /**
         * @dev Ids of all the markets in which the account has active positions by quote token
         */
        mapping(address => SetUtil.UintSet) activeMarketsPerQuoteToken;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeQuoteTokens;

        /**
         * @dev First market id that this account is active on
         */
        uint128 firstMarketId;

        /**
         * @dev If this boolean is set to true then the account is able to cross-collateral margin
         * @dev If this boolean is set to false then the account uses a single-token mode
         * @dev Single token mode means the account has a separate health factor for each collateral type
         */
        bytes32 accountMode;

        // todo: consider introducing empty slots for future use (also applies to other storage objects) (CR)
        // ref: https://github.com/Synthetixio/synthetix-v3/blob/08ea86daa550870ec07c47651394dbb0212eeca0/protocol/
        // synthetix/contracts/storage/Account.sol#L58
    }

    /**
     * @dev Creates an account for the given id, and associates it to the given owner.
     *
     * Note: Will not fail if the account already exists, and if so, will overwrite the existing owner.
     *  Whatever calls this internal function must first check that the account doesn't exist before re-creating it.
     */
    function create(uint128 id, address owner, bytes32 accountMode) 
        internal 
        returns (Data storage account) 
    {
        // Disallowing account ID 0 means we can use a non-zero accountId as an existence flag in structs like Position
        require(id != 0);

        account = load(id);

        account.id = id;
        account.setOwner(owner);
        AccountMode.setAccountMode(account, accountMode);
    }

     /**
     * @dev Returns the account stored at the specified account id.
     */
    function load(uint128 id) internal pure returns (Data storage account) {
        require(id != 0);
        bytes32 s = keccak256(abi.encode("xyz.voltz.Account", id));
        assembly {
            account.slot := s
        }
    }

    /**
     * @dev Reverts if the account does not exist with appropriate error. Otherwise, returns the account.
     */
    function exists(uint128 id) internal view returns (Data storage account) {
        Data storage a = load(id);
        if (a.rbac.owner == address(0)) {
            revert AccountNotFound(id);
        }

        return a;
    }

    /**
     * @dev Loads the Account object for the specified accountId,
     * and validates that sender has the specified permission. It also resets
     * the interaction timeout. These are different actions but they are merged
     * in a single function because loading an account and checking for a
     * permission is a very common use case in other parts of the code.
     */
    function loadAccountAndValidateOwnership(uint128 accountId, address senderAddress)
        internal
        view
        returns (Data storage account)
    {
        account = Account.load(accountId);
        if (account.rbac.owner != senderAddress) {
            revert PermissionDenied(accountId, senderAddress);
        }
    }

    /**
     * @dev Loads the Account object for the specified accountId,
     * and validates that sender has the specified permission. It also resets
     * the interaction timeout. These are different actions but they are merged
     * in a single function because loading an account and checking for a
     * permission is a very common use case in other parts of the code.
     */
    function loadAccountAndValidatePermission(uint128 accountId, bytes32 permission, address senderAddress)
        internal
        view
        returns (Data storage account)
    {
        account = Account.load(accountId);
        if (!account.authorized(permission, senderAddress)) {
            revert PermissionDenied(accountId, senderAddress);
        }
    }

    /**
     * @dev Sets the owner of the account.
     */
    function setOwner(Data storage self, address owner) internal {
        AccountRBAC.setOwner(self, owner);
    }

    /**
     * @dev Grants a particular permission to the specified target address.
     */
    function grantPermission(Data storage self, bytes32 permission, address target) internal {
        AccountRBAC.grantPermission(self, permission, target);
    }

    /**
     * @dev Revokes a particular permission from the specified target address.
     */
    function revokePermission(Data storage self, bytes32 permission, address target) internal {
        AccountRBAC.revokePermission(self, permission, target);
    }

    /**
     * @dev Revokes all permissions for the specified target address.
     * @notice only removes permissions for the given address, not for the entire account
     */
    function revokeAllPermissions(Data storage self, address target) internal {
        AccountRBAC.revokeAllPermissions(self, target);
    }

    /**
     * @dev Returns wether the specified address has the given permission.
     */
    function hasPermission(Data storage self, bytes32 permission, address target) internal view returns (bool) {
        return AccountRBAC.hasPermission(self, permission, target);
    }

    /**
     * @dev Returns wether the specified target address has the given permission, or has the high level admin permission.
     */
    function authorized(Data storage self, bytes32 permission, address target) internal view returns (bool) {
        return Account.authorized(self, permission, target);
    }

    /**
     * @dev Increments the account's collateral balance.
     */
    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        AccountCollateral.increaseCollateralBalance(self, collateralType, amount);
    }

    /**
     * @dev Decrements the account's collateral balance.
     */
    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        AccountCollateral.decreaseCollateralBalance(self, collateralType, amount);
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the account
     */
    function getCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256 collateralBalance)
    {
        collateralBalance = self.collateralBalances[collateralType];
    }

    function getWeightedCollateralBalanceInUSD(Data storage self) 
        internal 
        view
        returns (uint256 weightedCollateralBalanceInUSD) 
    {
        weightedCollateralBalanceInUSD = AccountCollateral.getWeightedCollateralBalanceInUSD(self);
    }

    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getWithdrawableCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256 collateralBalanceAvailable)
    {
        collateralBalanceAvailable = AccountCollateral.getWithdrawableCollateralBalance(self, collateralType);
    }

    /**
     * @dev Marks that the account is active on particular market.
     */
    function markActiveMarket(Data storage self, address collateralType, uint128 marketId) internal {
        AccountActiveMarket.markActiveMarket(self, collateralType, marketId);
    }

    function getMarginRequirementsAndHighestUnrealizedLoss(Account.Data storage self, address collateralType)
        internal
        view
        returns (MarginRequirement memory mr)
    {
        return AccountExposure.getMarginRequirementsAndHighestUnrealizedLoss(self, collateralType);
    }

    /**
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise  returns the initial margin requirement (single token account)
     */
    function imCheck(Data storage self, address collateralType) 
        internal 
        view 
        returns (MarginRequirement memory mr)
    {
        mr = self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
        
        if (!mr.isIMSatisfied) {
            revert AccountBelowIM(self.id, collateralType, mr);
        }
    }

    /**
     * @dev Changes the account mode.
     */
    function changeAccountMode(Data storage self, bytes32 newAccountMode) internal {
        AccountMode.changeAccountMode(self, newAccountMode);
    }

    /**
     * @dev Closes all account filled (i.e. attempts to fully unwind) and unfilled orders in all the markets in which the account
     * is active
     */
    function closeAccount(Data storage self, address collateralType) internal {
        SetUtil.UintSet storage markets = self.activeMarketsPerQuoteToken[collateralType];
            
        for (uint256 i = 1; i <= markets.length(); i++) {
            uint128 marketId = markets.valueAt(i).to128();
            Market.exists(marketId).closeAccount(self.id);
        }
    }

    function isEligibleForAutoExchange(Data storage self) internal view returns (bool) {

        // note, only applies to multi-token accounts
        // todo: needs to be exposed via e.g. the account module
        // todo: needs implementation -> within this need to take into account product -> market changes

        return false;
    }
}
