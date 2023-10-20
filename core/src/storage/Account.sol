/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import {Account} from "./Account.sol";
import {CollateralPool} from "./CollateralPool.sol";
import {Market} from "./Market.sol";

import { MarginInfo } from "../libraries/DataTypes.sol";

import {AccountActiveMarket} from "../libraries/account/AccountActiveMarket.sol";
import {AccountCollateral} from "../libraries/account/AccountCollateral.sol";
import {AccountExposure} from "../libraries/account/AccountExposure.sol";
import {AccountRBAC} from "../libraries/account/AccountRBAC.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/*
TODOs
    - why have auto-exchange specific functions referenced in here?
    - do we mark active quote tokens when an unfilled order is created?
    - consider introducing empty slots for future use (also applies to other storage objects)
*/


/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using Account for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using Market for Market.Data;
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
     * @dev Thrown when an account is already created
     */
    error AccountAlreadyExists(uint128 id);

    /**
     * @dev Thrown when the given target address does not own the given account.
     */
    error PermissionDenied(uint128 accountId, address target);

    /**
     * @dev Thrown when a given account's margin balance is below the initial margin requirement
     */
    error AccountBelowIM(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when a given account's margin balance is below the adl margin requirement
     */
    error AccountBelowAdl(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when a given account's margin balance is above the initial buffer margin requirement
     * @dev To be used during backstop lps liquidations
     * @param accountId The backstop lp account id
     * @param marginInfo The margin information for the backstop lp account.
     */
    error AccountAboveIMBuffer(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when a given account's margin balance is above the lm margin requirement
     * @dev To be used during ranked and dutch liquidations
     * @param accountId The account id
     * @param marginInfo The margin information for the account id
     */
    error AccountAboveLm(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when an account cannot be found.
     */
    error AccountNotFound(uint128 accountId);

    /**
    * @dev Thrown when account and counterparty belong to different collateral pools
    */
    error CollateralPoolMismatch(uint128 accountCollateralPoolId, uint128 counterpartyCollateralPoolId);

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

    struct LiquidationBidPriorityQueues {

        /**
         * @dev Id of the latest queue
         */
        uint256 latestQueueId;

        /**
         * @dev Block timestamp at which the latest queue stops being live
         */
        uint256 latestQueueEndTimestamp;

        /**
         * @dev Map of liquidation bid priority queues associated with the account
         */
        mapping(uint256 => LiquidationBidPriorityQueue.Heap) priorityQueues;

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
        mapping(address => int256) collateralShares;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeCollaterals;
    
        /**
         * @dev Ids of all the markets in which the account has active positions by quote token
         */
        mapping(address => SetUtil.UintSet) activeMarketsPerQuoteToken;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance or active positions
         */
        SetUtil.AddressSet activeQuoteTokens;

        /**
         * @dev First market id that this account is active on
         */
        uint128 firstMarketId;
        /**
         * @dev Liquidation Bid Priority Queues associated with the account alongside latest timestamp & id per
         * collateral bubble
         * collateralBubbleQuoteTokenAddress -> LiquidationBidPriorityQueues
         */
        mapping(address => LiquidationBidPriorityQueues) liquidationBidPriorityQueuesPerBubble;

    }

    /**
     * @dev Creates an account for the given id, and associates it to the given owner.
     */
    function create(uint128 id, address owner) 
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
    }

     /**
     * @dev Returns the account stored at the specified account id.
     */
    function load(uint128 id) private pure returns (Data storage account) {
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
        account = Account.exists(accountId);
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
        account = Account.exists(accountId);
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

    /**
     * @dev Reverts if the underlying collateral pool of the account is paused.
     */
    function ensureEnabledCollateralPool(Data storage self) internal view {
        // check if account is assigned to any collateral pool
        if (self.firstMarketId != 0) {
            // check if the underlying collateral pool is paused

            uint128 collateralPoolId = self.getCollateralPool().id;
            FeatureFlagSupport.ensureEnabledCollateralPool(collateralPoolId);
        }
    }

    function updateNetCollateralDeposits(Data storage self, address collateralType, int256 amount) internal {
        AccountCollateral.updateNetCollateralDeposits(self, collateralType, amount);
    }

    function getAccountNetCollateralDeposits(Data storage self, address collateralType)
        internal
        view
        returns (int256)
    {
        return AccountCollateral.getAccountNetCollateralDeposits(self, collateralType);
    }

    function getAccountWithdrawableCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256)
    {
        return AccountCollateral.getAccountWithdrawableCollateralBalance(self, collateralType);
    }

    function markActiveMarket(Data storage self, address collateralType, uint128 marketId) internal {
        AccountActiveMarket.markActiveMarket(self, collateralType, marketId);
    }

    function getMarginInfoByBubble(Account.Data storage self, address collateralType)
        internal
        view
        returns (MarginInfo memory)
    {
        return AccountExposure.getMarginInfoByBubble(self, collateralType);
    }

    function getMarginInfoByCollateralType(
        Account.Data storage self, 
        address collateralType, 
        CollateralPool.RiskMultipliers memory riskMultipliers
    )
        internal
        view
        returns (MarginInfo memory)
    {
        return AccountExposure.getMarginInfoByCollateralType(
            self, 
            collateralType, 
            riskMultipliers
        );
    }

    /**
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise returns the margin info (multi token account)
     */
    function imCheck(Data storage self) 
        internal 
        view 
        returns (MarginInfo memory marginInfo)
    {
        marginInfo = self.getMarginInfoByBubble(address(0));
        
        if (marginInfo.initialDelta < 0) {
            revert AccountBelowIM(self.id, marginInfo);
        }
    }

    function collateralPoolsCheck(
        uint128 liquidatableAccountCollateralPoolId,
        Account.Data storage liquidatorAccount
    ) internal view {

        // note, this function applies to both position liquidations and auto-exchange
        // liquidator and liquidatee should belong to the same collateral pool
        // note, it's fine for the liquidator to not belong to any collateral pool

        if (liquidatorAccount.firstMarketId != 0) {
            CollateralPool.Data storage liquidatorCollateralPool = liquidatorAccount.getCollateralPool();
            if (liquidatorCollateralPool.id != liquidatableAccountCollateralPoolId) {
                revert CollateralPoolMismatch(
                    liquidatorCollateralPool.id,
                    liquidatableAccountCollateralPoolId
                );
            }
        }
    }

    function betweenImAndImBufferCheck(Data storage self)
        internal
        view
        returns (MarginInfo memory marginInfo)
    {
        marginInfo = self.imCheck();

        if (marginInfo.initialBufferDelta > 0) {
            revert AccountAboveIMBuffer(self.id, marginInfo);
        }
    }

    /**
     * @dev Checks if the account is adl initial margin requirement and reverts if so,
     * otherwise returns the margin info (multi token account)
     */
    function adlCheck(Data storage self) 
        internal 
        view 
        returns (MarginInfo memory marginInfo)
    {
        marginInfo = self.getMarginInfoByBubble(address(0));
        
        if (marginInfo.adlDelta < 0) {
            revert AccountBelowAdl(self.id, marginInfo);
        }
    }

    function betweenAdlAndLmCheck(Data storage self)
        internal
        view 
        returns (MarginInfo memory marginInfo)
    {
        marginInfo = self.adlCheck();

        if (marginInfo.liquidationDelta > 0) {
            revert AccountAboveLm(self.id, marginInfo);
        }
    }
}
