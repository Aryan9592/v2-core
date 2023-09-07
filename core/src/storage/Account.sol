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
import {AccountRBAC} from "../libraries/account/AccountRBAC.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";
import {LiquidationBidPriorityQueue} from "../libraries/LiquidationBidPriorityQueue.sol";

import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import "../interfaces/external/IMarketManager.sol";


/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using Account for Account.Data;
    using Market for Market.Data;
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;

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
     * @dev Thrown when a given single-token account's account's total value is below the initial margin requirement
     * + the highest unrealized loss
     */
    error AccountBelowIM(uint128 accountId, MarginInfo marginInfo);

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
    error LiquidatorAndLiquidateeBelongToDifferentCollateralPools(uint128 liquidatorId);

    struct PnLComponents {
        /// @notice Accrued cashflows are all cashflows that are interchanged with a pool as a 
        /// result of having a positions open in a derivative instrument, as determined 
        /// by the derivative’s contractual obligations at certain timestamps.
        /// @dev e.g., perpetual futures require the interchange of a funding rate a regular intervals, 
        /// which would be reported as accrued cashflows; interest rate swaps also determine the 
        /// interchange of net accrued interest amounts, which are also accrued cashflows.
        int256 accruedCashflows;
        /// @notice Locked PnL are the component of PnL locked by unwinding exposure tokens. An 
        /// exception to this is when transactions in that exposure token are not in the 
        ////settlement token, but rather in a different token which would need to be burned 
        /// to result in a balance in the settlement token.
        /// @dev e.g., in the Voltz Protocol’s Interest rate swaps, exposure tokens are termed 
        /// variable tokens, and the Protocol’s vAMM always interchanges these variable tokens 
        /// against forward looking, fixed interest tokens as a way of pricing. Converting the 
        /// PnL locked by unwinding a variable token balance into the settlement token would require 
        /// burning the resulting fixed token balance.
        int256 lockedPnL;
        /// @notice Unrealized PnL is the valued accumulated in an open position when that position 
        /// is priced at market values (’mark to market’). As opposed to the previous components of PnL, 
        /// this component changes with time, as market prices change. Strictly speaking, then, unrealized PnL 
        /// is actually a function of time: unrealizedPnL(t).
        int256 unrealizedPnL;
    }

    struct MarginInfo {
        address collateralType;
        int256 netDeposits;
        /// These are all amounts that are available to contribute to cover margin requirements. 
        int256 marginBalance;
        /// The real balance is the balance that is in ‘cash’, that is, actually held in the settlement 
        /// token and not as value of an instrument which settles in that token
        int256 realBalance;
        /// Difference between margin balance and initial margin requirement
        int256 initialDelta;
        /// Difference between margin balance and liquidation margin requirement
        int256 liquidationDelta;
    }

    /**
     * @dev Structure for tracking one-side market exposure.
     */
    struct MarketExposure {
        /// @notice Annualized notional of the exposure
        int256 annualizedNotional;
        PnLComponents pnlComponents;
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
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeQuoteTokens;

        /**
         * @dev First market id that this account is active on
         */
        uint128 firstMarketId;
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
        returns (Account.MarginInfo memory)
    {
        return AccountExposure.getMarginInfoByBubble(self, collateralType);
    }

    function getMarginInfoByCollateralType(Account.Data storage self, address collateralType, UD60x18 imMultiplier)
        internal
        view
        returns (Account.MarginInfo memory)
    {
        return AccountExposure.getMarginInfoByCollateralType(self, collateralType, imMultiplier);
    }

    /**
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise  returns the initial margin requirement (single token account)
     */
    function imCheck(Data storage self, address collateralType) 
        internal 
        view 
        returns (Account.MarginInfo memory marginInfo)
    {
        marginInfo = self.getMarginInfoByBubble(collateralType);
        
        if (marginInfo.initialDelta < 0) {
            revert AccountBelowIM(self.id, marginInfo);
        }
    }

    // todo: during liquidations implementation
    // function isEligibleForAutoExchange(
    //     Account.Data storage self,
    //     address collateralType
    // )
    //     internal
    //     view
    //     returns (bool)
    // {
    //     return AccountAutoExchange.isEligibleForAutoExchange(self, collateralType);
    // }

    // todo: during liquidations implementation
    // function getMaxAmountToExchangeQuote(
    //     Account.Data storage self,
    //     address coveringToken,
    //     address autoExchangedToken
    // )
    //     internal
    //     view
    //     returns (uint256 /* coveringAmount */, uint256 /* autoExchangedAmount */ )
    // {
    //     return AccountAutoExchange.getMaxAmountToExchangeQuote(self, coveringToken, autoExchangedToken);
    // }

    // todo: consider moving to a separate library
    function validateLiquidationBid(
        Account.Data storage self,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        // collateral pool of the liquidated account
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        Account.Data storage liquidatorAccount = Account.loadAccountAndValidatePermission(
            liquidationBid.liquidatorAccountId,
            Account.ADMIN_PERMISSION,
            msg.sender
        );

        // liquidator and liquidatee should belong to the same collateral pool
        // note, it's fine for the liquidator to not belong to any collateral pool

        if (liquidatorAccount.firstMarketId != 0) {
            CollateralPool.Data storage liquidatorCollateralPool = liquidatorAccount.getCollateralPool();
            if (liquidatorCollateralPool.id != collateralPool.id) {
                revert LiquidatorAndLiquidateeBelongToDifferentCollateralPools(
                    liquidatorCollateralPool.id,
                    collateralPool.id
                );
            }
        }

        uint256 marketIdsLength = liquidationBid.marketIds.length;
        uint256 inputsLength = liquidationBid.inputs.length;

        if (marketIdsLength != inputsLength) {
            revert LiquidationBidMarketIdsAndInputsLengthMismatch(marketIdsLength, inputsLength);
        }

        if (marketIdsLength > collateralPool.riskConfig.maxNumberOfOrdersInLiquidationBid) {
            revert LiquidationBidOrdersOverflow(marketIdsLength,
                collateralPool.riskConfig.maxNumberOfOrdersInLiquidationBid);
        }

        // todo: all markets should belong to the collateral pool of the account and same collateral bubble
        // in theory this should be flagged during rank calculation?

    }

    // todo: consider moving to a separate library
    function computeLiquidationBidRank(
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal returns (uint256) {
        // todo: implement rank calculation
        return 0;
    }

    // todo: consider moving this logic to a separate library similar to account exposures, etc (CR)?
    function submitLiquidationBid(
        Account.Data storage self,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        // todo: submission of pre & post bid execution hooks
        // todo: check if the MMR condition is breached while the LM condition is still not breached
        // todo: make sure max length of a queue is not breached -> make it configurable in risk params

        self.validateLiquidationBid(liquidationBid);
        uint256 liquidationBidRank = computeLiquidationBidRank(liquidationBid);

        if (self.liquidationBidPriorityQueues.latestQueueEndTimestamp == 0 ||
            block.timestamp > self.liquidationBidPriorityQueues.latestQueueEndTimestamp
        ) {
            // this is the first liquidation bid ever to be submitted against this account id
            // or the latest queue has expired, so we need to push the bid into a new queue
            CollateralPool.Data storage collateralPool = self.getCollateralPool();
            uint256 liquidationBidPriorityQueueDurationInSeconds = collateralPool.riskConfig
            .liquidationBidPriorityQueueDurationInSeconds;
            self.liquidationBidPriorityQueues.latestQueueEndTimestamp = block.timestamp + liquidationBidPriorityQueueDurationInSeconds;
            self.liquidationBidPriorityQueues.latestQueueId += 1;
        }

        self.liquidationBidPriorityQueues.priorityQueues[self.liquidationBidPriorityQueues.latestQueueId].enqueue(
            liquidationBidRank,
            liquidationBid
        );

    }

    function executeTopRankedLiquidationBid(
        Account.Data storage self
    ) internal {

        // todo: check if liquidated and liquidator accounts exist
        // todo: make sure this can only be executed if lm is breached but dutchM is not (needs more thinking)
        // todo: add logic for liquidator rewards & allocation towards backstop lps and the insurance fund
        // todo: make sure the liquidator reward is applied before the im check
        // todo: make sure pre and post execution hooks are executed around this function
        // todo: fee collection flow for transfers from liquidations (do we want to collect fees in this case?)

        if (block.timestamp > self.liquidationBidPriorityQueues.latestQueueEndTimestamp) {
            // the latest queue has expired, hence we cannot execute its top ranked liquidation bid
            revert LiquidationBidPriorityQueueExpired(
                self.liquidationBidPriorityQueues.latestQueueId,
                self.liquidationBidPriorityQueues.latestQueueEndTimestamp
            );
        }

        // extract top ranked order (don't dequeue it yet)

        LiquidationBidPriorityQueue.LiquidationBid memory topRankedLiquidationBid = self.liquidationBidPriorityQueues
        .priorityQueues[
            self.liquidationBidPriorityQueues.latestQueueId
        ].topBid();

        // execute orders within the liquidation bid

        for (uint256 i = 0; i < topRankedLiquidationBid.marketIds.length; i++) {
            uint128 marketId = topRankedLiquidationBid.marketIds[i];
            Market.Data memory market = Market.exists(marketId);
            IMarketManager marketManager = IMarketManager(market.marketManagerAddress);
            marketManager.executeLiquidationOrder(self.id, topRankedLiquidationBid.liquidatorAccountId,  marketId,
                topRankedLiquidationBid.inputs[i]);
        }

        // check if the liquidator satisfies the IM requirement

        bool isBelowIM = Account.exists(topRankedLiquidationBid.liquidatorAccountId)
            .getMarginInfoByBubble(address(0)).initialDelta < 0;

        if (isBelowIM) {
            // todo: similar logic to the above except we're reversing here
            for (uint256 i = 0; i < topRankedLiquidationBid.marketIds.length; i++) {
                uint128 marketId = topRankedLiquidationBid.marketIds[i];
                Market.Data memory market = Market.exists(marketId);
                IMarketManager marketManager = IMarketManager(market.marketManagerAddress);
                marketManager.reverseLiquidationOrder(self.id, topRankedLiquidationBid.liquidatorAccountId,  marketId,
                    topRankedLiquidationBid.inputs[i]);
            }
        }

        self.liquidationBidPriorityQueues.priorityQueues[
            self.liquidationBidPriorityQueues.latestQueueId
        ].dequeue();

    }

    function closeAllUnfilledOrders(
        Account.Data storage self
    ) internal {
        // todo: implement
    }

}
