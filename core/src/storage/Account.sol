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
import "./AutoExchangeConfiguration.sol";

import "../libraries/AccountActiveMarket.sol";
import "../libraries/AccountCollateral.sol";
import "../libraries/AccountExposure.sol";
import "../libraries/AccountMode.sol";
import "../libraries/AccountRBAC.sol";


import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using Account for Account.Data;
    using Market for Market.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
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
     * @dev Thrown when an account is already created
     */
    error AccountAlreadyExists(uint128 id);

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

    /**
     * @dev Structure for tracking margin requirement information.
     */
    struct MarginRequirement {
        bool isIMSatisfied;
        bool isLMSatisfied;
        uint256 initialMarginRequirement;
        uint256 liquidationMarginRequirement;
        uint256 highestUnrealizedLoss;
        uint256 availableCollateralBalance;
        address collateralType;
    }

    /**
     * @dev Structure for tracking one-side market exposure.
     */
    struct MarketExposure {
        int256 annualizedNotional;
        // note, in context of dated irs with the current accounting logic it also includes accruedInterest
        uint256 unrealizedLoss;
    }

    /**
     * @dev Structure for tracking maker (two-side) market exposure.
     */
    struct MakerMarketExposure {
        MarketExposure lower;
        MarketExposure upper;
    }

    /**
     * @dev Structure for tracking access control for the account.
     */
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
         * @dev Account mode (i.e. single-token or multi-token mode)
         */
        bytes32 accountMode;

        // todo: consider introducing empty slots for future use (also applies to other storage objects) (CR)
        // ref: https://github.com/Synthetixio/synthetix-v3/blob/08ea86daa550870ec07c47651394dbb0212eeca0/protocol/
        // synthetix/contracts/storage/Account.sol#L58
    }

    /**
     * @dev Creates an account for the given id, and associates it to the given owner.
     */
    function create(uint128 id, address owner, bytes32 accountMode) 
        internal 
        returns (Data storage account) 
    {
        // disallowing account ID 0 means we can use a non-zero accountId as an existence flag in structs like Position
        if (id == 0) {
            revert AccountAlreadyExists(id);
        }

        // load the account data
        account = load(id);

        // if the account id is non-zero, it means that the account has already been created
        if (account.id != 0) {
            revert AccountAlreadyExists(id);
        }

        // set the account details
        account.id = id;
        account.setOwner(owner);
        AccountMode.setAccountMode(account, accountMode);
    }

     /**
     * @dev Returns the account stored at the specified account id.
     */
    function load(uint128 id) internal pure returns (Data storage account) {
        if (id == 0) {
            revert AccountNotFound(id);
        }

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

        // if the account id is zero, it means that the account has not been created yet
        if (a.id == 0) {
            revert AccountNotFound(id);
        }

        return a;
    }

    /**
     * @dev Loads the Account object for the specified accountId,
     * and validates that sender has the specified permission.
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
     * and validates that sender has the specified permission.
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

    function setOwner(Data storage self, address owner) internal {
        AccountRBAC.setOwner(self, owner);
    }

    function grantPermission(Data storage self, bytes32 permission, address target) internal {
        AccountRBAC.grantPermission(self, permission, target);
    }
    
    function revokePermission(Data storage self, bytes32 permission, address target) internal {
        AccountRBAC.revokePermission(self, permission, target);
    }
    
    function revokeAllPermissions(Data storage self, address target) internal {
        AccountRBAC.revokeAllPermissions(self, target);
    }

    function hasPermission(Data storage self, bytes32 permission, address target) internal view returns (bool) {
        return AccountRBAC.hasPermission(self, permission, target);
    }
    
    function authorized(Data storage self, bytes32 permission, address target) internal view returns (bool) {
        return AccountRBAC.authorized(self, permission, target);
    }

    /**
     * @dev Returns the root collateral pool of the account
     */
    function getCollateralPool(Data storage self) internal view returns (CollateralPool.Data storage) {
        return Market.exists(self.firstMarketId).getCollateralPool();
    }

    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        AccountCollateral.increaseCollateralBalance(self, collateralType, amount);
    }

    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        AccountCollateral.decreaseCollateralBalance(self, collateralType, amount);
    }

    function getCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256)
    {
        return AccountCollateral.getCollateralBalance(self, collateralType);
    }

    function getWeightedCollateralBalanceInUSD(Data storage self) 
        internal 
        view
        returns (uint256) 
    {
        return AccountCollateral.getWeightedCollateralBalanceInUSD(self);
    }

    function getWithdrawableCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256)
    {
        return AccountCollateral.getWithdrawableCollateralBalance(self, collateralType);
    }

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

    // todo: needs implementation -> within this need to take into account product -> market changes
    function isEligibleForAutoExchange(Data storage self, address settlementType) internal view returns (bool) {

        if(self.accountMode == SINGLE_TOKEN_MODE) {
            return false;
        }

        int256 accountValueBySettlementType = self.getAccountValueByCollateralType(settlementType);

        if (accountValueBySettlementType > 0) {
            return false;
        }

        AutoExchangeConfiguration.Data memory autoExchangeConfig = 
            AutoExchangeConfiguration.load();

        if ((-accountValueBySettlementType).toUint() > autoExchangeConfig.singleAutoExchangeThreshold) {
            return true;
        }

        uint256 sumOfNegativeAccountValues_U;
        int256 totalAccountValue_U;
        for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
            address collateralType = self.activeQuoteTokens.valueAt(i);
            int256 accountValueByCollateralType_U = self.getAccountValueByCollateralType_U(collateralType);
            sumOfNegativeAccountValues_U += accountValueByCollateralType_U < 0 ?
                (-accountValueByCollateralType_U).toUint() : 0;
            totalAccountValue_U += accountValueByCollateralType_U;
        }
        // note: activeQuoteTokens does not include collateral tokens 
        // that are not collaterals of active markets. These feed into the totalAccountValue_U
        for (uint256 i = 1; i <= self.activeCollaterals.length(); i++) {
            address collateralType = self.activeCollaterals.valueAt(i);
            if (!self.activeQuoteTokens.contains(collateralType)) {
                int256 accountValueByCollateralType_U = self.getAccountValueByCollateralType_U(collateralType);
                totalAccountValue_U += accountValueByCollateralType_U;
            }
        }
        
        if (sumOfNegativeAccountValues_U > autoExchangeConfig.totalAutoExchangeThreshold) {
            return true;
        }

        // todo: this will fail if totalAccountValue_U is negative. decide on action.
        if (
            sumOfNegativeAccountValues_U > 
            mulUDxUint(autoExchangeConfig.negativeCollateralBalancesMultiplier, totalAccountValue_U.toUint())
        ) {
            return true;
        }

        return false;
    }

    // todo: include realized PnL and replace unrealized loss with unrealized PnL
    function getAccountValueByCollateralType(
        Data storage self,
        address collateralType
    ) internal view returns (int256 accountValue) {
        (, uint256 highestUnrealizedLoss) = AccountExposure.getRequirementsAndHighestUnrealizedLossByCollateralType(self, collateralType);

        accountValue = self.getCollateralBalance(collateralType).toInt() - highestUnrealizedLoss.toInt();
    }

    function getAccountValueByCollateralType_U(
        Data storage self,
        address collateralType
    ) internal view returns (int256) {
        int256 accountValueByCollateralType = self.getAccountValueByCollateralType(collateralType);

        uint256 accountValueByCollateralType_U = CollateralConfiguration.load(collateralType)
            .getCollateralInUSD(
                accountValueByCollateralType > 0 ? 
                    accountValueByCollateralType.toUint() :
                    (-accountValueByCollateralType).toUint()
            );

        return accountValueByCollateralType > 0 ? accountValueByCollateralType_U.toInt() :
            -accountValueByCollateralType_U.toInt();
    }


    //// PURE FUNCTIONS ////

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
}
