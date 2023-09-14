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

import {AccountActiveMarket} from "../libraries/account/AccountActiveMarket.sol";
import {AccountAutoExchange} from "../libraries/account/AccountAutoExchange.sol";
import {AccountCollateral} from "../libraries/account/AccountCollateral.sol";
import {AccountExposure} from "../libraries/account/AccountExposure.sol";
import {AccountMode} from "../libraries/account/AccountMode.sol";
import {AccountRBAC} from "../libraries/account/AccountRBAC.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18, mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import "../interfaces/external/IMarketManager.sol";


/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using Account for Account.Data;
    using Market for Market.Data;
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;

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
     * @dev Thrown when a given account's account's total value is below the initial margin requirement
     * + the highest unrealized loss
     */
    error AccountBelowIM(uint128 accountId, MarginRequirementDeltas marginRequirements);

    /**
     * @dev Thrown when account is not between the maintenance margin requirement and the liquidation margin requirement
     */
    error AccountNotBetweenMmrAndLm(uint128 accountId, MarginRequirementDeltas marginRequirements);

    /**
     * @dev Thrown when account is not below the liquidation margin requirement
     */
    error AccountNotBelowLM(uint128 accountId, MarginRequirementDeltas marginRequirements);

    /**
     * @dev Thrown when account is not below the maintenance margin requirement
     */
    error AccountNotBelowMMR(uint128 accountId, MarginRequirementDeltas marginRequirements);

    /**
     * @dev Thrown when an account cannot be found.
     */
    error AccountNotFound(uint128 accountId);

    /**
     * @dev Thrown when attempting to execute a bid in an expired liquidation bid priority queue
     */
    error LiquidationBidPriorityQueueExpired(uint256 queueId, uint256 queueEndTimestamp);

    /**
      * @dev Thrown when attempting to submit into a queue that is full
     */
    error LiquidationBidPriorityQueueOverflow(uint256 queueId, uint256 queueEndTimestamp, uint256 queueLength);

    /**
      * @dev Thrown when attempting to submit a liquidation bid where number of markets and bytes inputs don't match
     */
    error LiquidationBidMarketIdsAndInputsLengthMismatch(uint256 marketIdsLength, uint256 inputsLength);

    /**
      * @dev Thrown when attempting to submit a liquidation bid where the number of orders exceeds the maximum allowed
     */
    error LiquidationBidOrdersOverflow(uint256 ordersLength, uint256 maxOrders);

    /**
      * @dev Thrown when attempting the liquidation bidder belongs to a different collateral pool from the liquidatee
    */
    error LiquidatorAndLiquidateeBelongToDifferentCollateralPools(uint128 liquidatorCollateralPoolId,
        uint128 liquidateeCollateralPoolId);

    /**
      * @dev Thrown if an account has unfilled orders in any of its active markets
    */
    error AccountHasUnfilledOrders(uint128 accountId);

    /**
    * @dev Thrown if attempting to perform a dutch liquidation while the account is above the dutch
    * margin requirement threshold and the liquidation bid queue is not empty
    */
    error AccountIsAboveDutchAndLiquidationBidQueueIsNotEmpty(uint128 accountId);

    /**
    * @dev Thrown if a liquidation causes the lm delta to get even more negative than it was before the liquidation
    */
    error LiquidationCausedNegativeLMDeltaChange(uint128 accountId, int256 lmDeltaChange);

    /**
     * @dev Structure for tracking margin requirement information.
     */
    struct MarginRequirementDeltas {
        int256 initialDelta;
        int256 maintenanceDelta;
        int256 liquidationDelta;
        int256 dutchDelta;
        int256 adlDelta;
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
        mapping(address => uint256) collateralShares;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeCollaterals;
    
        /**
         * @dev Ids of all the markets in which the account has active positions by quote token
         */
        mapping(address => SetUtil.UintSet) activeMarketsPerQuoteToken;


        // todo: do we mark active quote tokens when an unfilled order is created?
        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance or active positions
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

        /**
         * @dev Liquidation Bid Priority Queues associated with the account alongside latest timestamp & id
         */
        LiquidationBidPriorityQueues liquidationBidPriorityQueues;

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
     * @dev Returns false if the account does not exist with appropriate error. Otherwise, returns true.
     */
    function doesExist(uint128 id) internal view returns (bool) {
        Data storage a = load(id);

        // if the account id is zero, it means that the account has not been created yet
        return a.id != 0;
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

    function getRequirementDeltasByBubble(Account.Data storage self, address collateralType)
        internal
        view
        returns (Account.MarginRequirementDeltas memory)
    {
        return AccountExposure.getRequirementDeltasByBubble(self, collateralType);
    }

    function getRequirementDeltasByCollateralType(Account.Data storage self, address collateralType,
        UD60x18 imMultiplier, UD60x18 mmrMultiplier, UD60x18 dutchMultiplier, UD60x18 adlMultiplier)
        internal
        view
        returns (Account.MarginRequirementDeltas memory)
    {
        return AccountExposure.getRequirementDeltasByCollateralType(
            self,
            collateralType,
            imMultiplier,
            mmrMultiplier,
            dutchMultiplier,
            adlMultiplier
        );
    }

    // todo: lots of margin requirement check functions, is it even worth having the one-off ones as helpers?

    /**
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise  returns the initial margin requirement (single token account)
     */
    function imCheck(Data storage self, address collateralType) 
        internal 
        view 
        returns (Account.MarginRequirementDeltas memory mr)
    {
        mr = self.getRequirementDeltasByBubble(collateralType);
        
        if (mr.initialDelta < 0) {
            revert AccountBelowIM(self.id, mr);
        }
    }

    /**
     * @dev Checks if the account is below maintenance margin requirement and above
     * liquidation margin requirement, if that's not the case revert
     */
    function isBetweenMmrAndLmCheck(Data storage self, address collateralType) internal view returns
    (Account.MarginRequirementDeltas memory mr) {
        mr = self.getRequirementDeltasByBubble(collateralType);

        if (!(mr.maintenanceDelta < 0 && mr.liquidationDelta > 0)) {
            revert AccountNotBetweenMmrAndLm(self.id, mr);
        }

    }

    /**
     * @dev Checks if the account is below the liquidation margin requirement
     * and reverts if that's not the case (i.e. reverts if the lm requirement is satisfied by the account)
     */
    function isBelowLMCheck(Data storage self, address collateralType) internal view returns
    (Account.MarginRequirementDeltas memory mr) {

        mr = self.getRequirementDeltasByBubble(collateralType);

        if (mr.liquidationDelta > 0) {
            revert AccountNotBelowLM(self.id, mr);
        }

    }

    /**
     * @dev Checks if the account is below the maintenance margin requirement
     * and reverts if that's not the case (i.e. reverts if the mmr requirement is satisfied by the account)
     */
    function isBelowMMRCheck(Data storage self, address collateralType) internal view returns
    (Account.MarginRequirementDeltas memory mr) {

        mr = self.getRequirementDeltasByBubble(collateralType);

        if (mr.maintenanceDelta > 0) {
            revert AccountNotBelowMMR(self.id, mr);
        }

    }

    /**
     * @dev Checks if the account is above the dutch margin requirement
     * if that's the case, return true, otherwise return false
     */
    function isAboveDutch(Data storage self, address collateralType) internal view returns (bool) {
        Account.MarginRequirementDeltas memory mr = self.getRequirementDeltasByBubble(collateralType);
        return mr.dutchDelta > 0;
    }

    function changeAccountMode(Data storage self, bytes32 newAccountMode) internal {
        AccountMode.changeAccountMode(self, newAccountMode);
    }

    function isEligibleForAutoExchange(
        Account.Data storage self,
        address collateralType
    )
        internal
        view
        returns (bool)
    {
        return AccountAutoExchange.isEligibleForAutoExchange(self, collateralType);
    }

    function getMaxAmountToExchangeQuote(
        Account.Data storage self,
        address coveringToken,
        address autoExchangedToken
    )
        internal
        view
        returns (uint256 /* coveringAmount */, uint256 /* autoExchangedAmount */ )
    {
        return AccountAutoExchange.getMaxAmountToExchangeQuote(self, coveringToken, autoExchangedToken);
    }

    function collateralPoolsCheck(
        uint128 liquidatableAccountCollateralPoolId,
        Account.Data storage liquidatorAccount
    ) internal {

        // liquidator and liquidatee should belong to the same collateral pool
        // note, it's fine for the liquidator to not belong to any collateral pool

        if (liquidatorAccount.firstMarketId != 0) {
            CollateralPool.Data storage liquidatorCollateralPool = liquidatorAccount.getCollateralPool();
            if (liquidatorCollateralPool.id != liquidatableAccountCollateralPoolId) {
                revert LiquidatorAndLiquidateeBelongToDifferentCollateralPools(
                    liquidatorCollateralPool.id,
                    liquidatableAccountCollateralPoolId
                );
            }
        }
    }

    function validateLiquidationBid(
        Account.Data storage self,
        Account.Data storage liquidatorAccount,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        collateralPoolsCheck(collateralPool.id, liquidatorAccount);

        uint256 marketIdsLength = liquidationBid.marketIds.length;
        uint256 inputsLength = liquidationBid.inputs.length;

        if (marketIdsLength != inputsLength) {
            revert LiquidationBidMarketIdsAndInputsLengthMismatch(marketIdsLength, inputsLength);
        }

        if (marketIdsLength > collateralPool.riskConfig.maxNumberOfOrdersInLiquidationBid) {
            revert LiquidationBidOrdersOverflow(marketIdsLength,
                collateralPool.riskConfig.maxNumberOfOrdersInLiquidationBid);
        }

    }

    function computeLiquidationBidRank(
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal returns (uint256) {
        // implement
        // note, the ranking function should revert if the liquidation bid is attempting to liquidate more exposure
        // than the user has
        // also note, the ranking function should revert if the liquidation bid is attempting to touch non-active markets
        return 0;
    }

    function submitLiquidationBid(
        Account.Data storage self,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        self.isBetweenMmrAndLmCheck(address(0));

        Account.Data storage liquidatorAccount = Account.loadAccountAndValidatePermission(
            liquidationBid.liquidatorAccountId,
            Account.ADMIN_PERMISSION,
            msg.sender
        );

        self.validateLiquidationBid(liquidatorAccount, liquidationBid);
        uint256 liquidationBidRank = computeLiquidationBidRank(liquidationBid);
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        if (self.liquidationBidPriorityQueues.latestQueueEndTimestamp == 0 ||
            block.timestamp > self.liquidationBidPriorityQueues.latestQueueEndTimestamp
        ) {
            // this is the first liquidation bid ever to be submitted against this account id
            // or the latest queue has expired, so we need to push the bid into a new queue
            uint256 liquidationBidPriorityQueueDurationInSeconds = collateralPool.riskConfig
            .liquidationBidPriorityQueueDurationInSeconds;
            self.liquidationBidPriorityQueues.latestQueueEndTimestamp = block.timestamp
            + liquidationBidPriorityQueueDurationInSeconds;
            self.liquidationBidPriorityQueues.latestQueueId += 1;
        }

        self.liquidationBidPriorityQueues.priorityQueues[self.liquidationBidPriorityQueues.latestQueueId].enqueue(
            liquidationBidRank,
            liquidationBid
        );

        if (self.liquidationBidPriorityQueues.priorityQueues
        [self.liquidationBidPriorityQueues.latestQueueId].ranks.length >
            collateralPool.riskConfig.maxNumberOfBidsInLiquidationBidPriorityQueue) {
            revert LiquidationBidPriorityQueueOverflow(
            self.liquidationBidPriorityQueues.latestQueueId,
            self.liquidationBidPriorityQueues.latestQueueEndTimestamp,
                self.liquidationBidPriorityQueues.priorityQueues
                [self.liquidationBidPriorityQueues.latestQueueId].ranks.length
            );
        }

        liquidatorAccount.imCheck(address(0));

    }


    function closeAllUnfilledOrders(
        Account.Data storage self,
        uint128 liquidatorAccountId
    ) internal {

        self.isBelowMMRCheck(address(0));

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        collateralPoolsCheck(collateralPool.id, liquidatorAccount);

        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];
            int256 lmDeltaBeforeLiquidation = self.getRequirementDeltasByBubble(quoteToken).liquidationDelta;
            uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
            for (uint256 j = 0; i < markets.length; j++) {
                uint128 marketId = markets[j].to128();
                Market.exists(marketId).closeAllUnfilledOrders(self.id);
            }
            int256 lmDeltaChange = self.getRequirementDeltasByBubble(quoteToken).liquidationDelta
            - lmDeltaBeforeLiquidation;

            if (lmDeltaChange < 0) {
                revert LiquidationCausedNegativeLMDeltaChange(self.id, lmDeltaChange);
            }

            uint256 liquidationPenalty = mulUDxUint(
                collateralPool.riskConfig.unfilledOrderLiquidationPenaltyParameter,
                lmDeltaChange.toUint()
            );

            self.distributeLiquidationPenalty(liquidatorAccount, liquidationPenalty, quoteToken);
        }

    }

    function hasUnfilledOrders(
        Account.Data storage self
    ) internal {
        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];
            uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
            for (uint256 j = 0; i < markets.length; j++) {
                uint128 marketId = markets[j].to128();
                bool hasUnfilledOrdersInMarket = Market.exists(marketId).hasUnfilledOrders(self.id);

                if (hasUnfilledOrdersInMarket) {
                    revert AccountHasUnfilledOrders(self.id);
                }

            }
        }

    }

    function computeDutchLiquidationPenaltyParameter(Account.Data storage self) internal view returns (UD60x18) {
        // todo: implement
        return UD60x18.wrap(10e17);
    }

    function distributeLiquidationPenalty(
        Account.Data storage self,
        Account.Data storage liquidatorAccount,
        uint256 liquidationPenalty,
        address token
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        Account.Data storage insuranceFundAccount = Account.exists(collateralPool.insuranceFundConfig.accountId);
        Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);

        uint256 insuranceFundReward = mulUDxUint(
            collateralPool.insuranceFundConfig.liquidationFee,
            liquidationPenalty
        );
        uint256 backstopLPReward = mulUDxUint(
            collateralPool.backstopLPConfig.liquidationFee,
            liquidationPenalty
        );
        uint256 liquidatorReward = liquidationPenalty - insuranceFundReward - backstopLPReward;

        self.decreaseCollateralBalance(token, liquidationPenalty);
        insuranceFundAccount.increaseCollateralBalance(token, insuranceFundReward);
        backstopLpAccount.increaseCollateralBalance(token, backstopLPReward);
        liquidatorAccount.increaseCollateralBalance(token, liquidatorReward);
    }

    function executeDutchLiquidation(
        Account.Data storage self,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes memory inputs
    ) internal {

        // todo: consider reverting if the market is paused? (can be implemented in the market manager)

        // revert if account has unfilled orders that are not closed yet
        self.hasUnfilledOrders();

        // revert if account is not below liquidation margin requirement
        self.isBelowLMCheck(address(0));

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        collateralPoolsCheck(self.getCollateralPool().id, liquidatorAccount);

        // revert if the account is above dutch margin requirement & the liquidation bid queue is not empty
        uint256 liquidationBidQueueLength = self.liquidationBidPriorityQueues.priorityQueues
        [self.liquidationBidPriorityQueues.latestQueueId].ranks.length;

        if (liquidationBidQueueLength > 0 && self.isAboveDutch(address(0))) {
            revert AccountIsAboveDutchAndLiquidationBidQueueIsNotEmpty(
                self.id
            );
        }

        UD60x18 liquidationPenaltyParameter = self.computeDutchLiquidationPenaltyParameter();

        Market.Data storage market = Market.exists(marketId);

        int256 lmDeltaBeforeLiquidation = self.getRequirementDeltasByBubble(market.quoteToken).liquidationDelta;

        market.executeLiquidationOrder(
            self.id,
            liquidatorAccountId,
            inputs
        );

        int256 lmDeltaChange = self.getRequirementDeltasByBubble(market.quoteToken).liquidationDelta
        - lmDeltaBeforeLiquidation;

        if (lmDeltaChange < 0) {
            revert LiquidationCausedNegativeLMDeltaChange(self.id, lmDeltaChange);
        }

        uint256 liquidationPenalty = mulUDxUint(
            liquidationPenaltyParameter,
            lmDeltaChange.toUint()
        );

        self.distributeLiquidationPenalty(liquidatorAccount, liquidationPenalty, market.quoteToken);

        liquidatorAccount.imCheck(address(0));

    }

}
