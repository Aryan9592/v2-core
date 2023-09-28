/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/*
TODOs
    - adl positons that are in profit at current prices
    - lots of margin requirement check functions, is it even worth having the one-off ones as helpers?
    - collateralPoolsCheck, is this function a duplicate of an existing one?
    - add reference to quote token of the queue when throwing queue errors
    - is there a way to re-use LiquidationOrder struct in liquidation bid and other places where relevant?
    - implement dutch reward parameter calculation
    - implement rank calculation
    - remove address collateralType from im and lm checks
    - make sure dutch and ranked liquidation orders can only be executed while below lm and above adl margin req
*/


import {Account} from "../../storage/Account.sol";
import {Market} from "../../storage/Market.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {LiquidationBidPriorityQueue} from "../LiquidationBidPriorityQueue.sol";
import { UD60x18, mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import "../../interfaces/external/IMarketManager.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

/**
 * @title Object for managing account liquidation utilities
*/
library AccountLiquidation {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using LiquidationBidPriorityQueue for LiquidationBidPriorityQueue.Heap;
    using Market for Market.Data;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;

    /**
     * @dev Thrown when account is not between the maintenance margin requirement and the liquidation margin requirement
     */
    error AccountNotBetweenMmrAndLm(uint128 accountId, Account.MarginInfo marginInfo);

    /**
     * @dev Thrown when account is not below the liquidation margin requirement
     */
    error AccountNotBelowLM(uint128 accountId, Account.MarginInfo marginInfo);

    /**
     * @dev Thrown when account is not below the adl margin requirement
     */
    error AccountNotBelowADL(uint128 accountId, Account.MarginInfo marginInfo);

    /**
     * @dev Thrown when account is not below the maintenance margin requirement
     */
    error AccountNotBelowMMR(uint128 accountId, Account.MarginInfo marginInfo);


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
    * @dev Thrown if a liquidation bid quote token doesn't match the quote token of the market where
    * a liquidation order should be executed
    */
    error LiquidationBidQuoteTokenMismatch(address liquidationBidQuoteToken, address marketQuoteToken);

    struct LiquidationOrder {
        uint128 marketId;
        bytes inputs;
    }


    /**
     * @dev Checks if the account is below the liquidation margin requirement
     * and reverts if that's not the case (i.e. reverts if the lm requirement is satisfied by the account)
     */
    function isBelowLMCheck(Account.Data storage self, address collateralType) private view returns
    (Account.MarginInfo memory marginInfo) {

        marginInfo = self.getMarginInfoByBubble(collateralType);

        if (marginInfo.liquidationDelta > 0) {
            revert AccountNotBelowLM(self.id, marginInfo);
        }

    }

    /**
     * @dev Checks if an account is insolvent in a given bubble (assuming auto-exchange is exhausted!!!)
     * and returns the shortfall
     */
    function isInsolvent(Account.Data storage self, address collateralType) private view returns (bool, int256) {
        // todo: note, doing too many redundunt calculations, can be optimized
        // todo: consider reverting if address(0) is provided as collateralType
        // consider baking this function into the backstop lp function if it's not used anywhere else

        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(collateralType);
        return (marginInfo.collateralInfo.marginBalance < 0, marginInfo.collateralInfo.marginBalance);
    }


    function collateralPoolsCheck(
        uint128 liquidatableAccountCollateralPoolId,
        Account.Data storage liquidatorAccount
    ) private {

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
    ) private {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        collateralPoolsCheck(collateralPool.id, liquidatorAccount);

        uint256 marketIdsLength = liquidationBid.marketIds.length;
        uint256 inputsLength = liquidationBid.inputs.length;

        if (marketIdsLength != inputsLength) {
            revert LiquidationBidMarketIdsAndInputsLengthMismatch(marketIdsLength, inputsLength);
        }

        if (marketIdsLength > collateralPool.riskConfig.liquidationConfiguration.maxOrdersInBid) {
            revert LiquidationBidOrdersOverflow(marketIdsLength,
                collateralPool.riskConfig.liquidationConfiguration.maxOrdersInBid);
        }

        for (uint256 i = 0; i < marketIdsLength; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            Market.Data storage market = Market.exists(marketId);
            if (market.quoteToken != liquidationBid.quoteToken) {
                revert LiquidationBidQuoteTokenMismatch(liquidationBid.quoteToken, market.quoteToken);
            }
            market.validateLiquidationOrder(
                self.id,
                liquidationBid.inputs[i]
            );
        }

    }

    function computeLiquidationBidRank(
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) private returns (uint256) {
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

        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));

        if (!(marginInfo.maintenanceDelta < 0 && marginInfo.liquidationDelta > 0)) {
            revert AccountNotBetweenMmrAndLm(self.id, marginInfo);
        }

        Account.Data storage liquidatorAccount = Account.loadAccountAndValidatePermission(
            liquidationBid.liquidatorAccountId,
            Account.ADMIN_PERMISSION,
            msg.sender
        );

        validateLiquidationBid(self, liquidatorAccount, liquidationBid);
        uint256 liquidationBidRank = computeLiquidationBidRank(liquidationBid);
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        Account.LiquidationBidPriorityQueues storage liquidationBidPriorityQueues =
        self.liquidationBidPriorityQueuesPerBubble[liquidationBid.quoteToken];

        if (liquidationBidPriorityQueues.latestQueueEndTimestamp == 0 ||
            block.timestamp > liquidationBidPriorityQueues.latestQueueEndTimestamp
        ) {
            // this is the first liquidation bid ever to be submitted against this account id
            // or the latest queue has expired, so we need to push the bid into a new queue
            uint256 queueDurationInSeconds = collateralPool.riskConfig
            .liquidationConfiguration.queueDurationInSeconds;
            liquidationBidPriorityQueues.latestQueueEndTimestamp = block.timestamp
            + queueDurationInSeconds;
            liquidationBidPriorityQueues.latestQueueId += 1;
        }

        liquidationBidPriorityQueues.priorityQueues[liquidationBidPriorityQueues.latestQueueId].enqueue(
            liquidationBidRank,
            liquidationBid
        );

        if (liquidationBidPriorityQueues.priorityQueues
        [liquidationBidPriorityQueues.latestQueueId].ranks.length >
            collateralPool.riskConfig.liquidationConfiguration.maxBidsInQueue) {
            revert LiquidationBidPriorityQueueOverflow(
                liquidationBidPriorityQueues.latestQueueId,
                liquidationBidPriorityQueues.latestQueueEndTimestamp,
                liquidationBidPriorityQueues.priorityQueues
                [liquidationBidPriorityQueues.latestQueueId].ranks.length
            );
        }

        liquidatorAccount.imCheck(address(0));

    }


    function closeAllUnfilledOrders(
        Account.Data storage self,
        uint128 liquidatorAccountId
    ) internal {

        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));

        if (marginInfo.maintenanceDelta > 0) {
            revert AccountNotBelowMMR(self.id, marginInfo);
        }

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        collateralPoolsCheck(collateralPool.id, liquidatorAccount);

        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];
            int256 lmDeltaBeforeLiquidation = self.getMarginInfoByBubble(quoteToken).liquidationDelta;
            uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
            for (uint256 j = 0; j < markets.length; j++) {
                uint128 marketId = markets[j].to128();
                Market.exists(marketId).closeAllUnfilledOrders(self.id);
            }
            int256 lmDeltaChange = self.getMarginInfoByBubble(quoteToken).liquidationDelta
            - lmDeltaBeforeLiquidation;

            if (lmDeltaChange < 0) {
                revert LiquidationCausedNegativeLMDeltaChange(self.id, lmDeltaChange);
            }

            distributeLiquidationPenalty(
                self,
                liquidatorAccount,
                mulUDxUint(
                    collateralPool.riskConfig.liquidationConfiguration.unfilledPenaltyParameter,
                    lmDeltaChange.toUint()
                ),
                quoteToken,
                0);
        }

    }


    function hasUnfilledOrders(
        Account.Data storage self
    ) internal view {
        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];
            uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
            for (uint256 j = 0; j < markets.length; j++) {
                uint128 marketId = markets[j].to128();
                bool hasUnfilledOrdersInMarket = Market.exists(marketId).hasUnfilledOrders(self.id);

                if (hasUnfilledOrdersInMarket) {
                    revert AccountHasUnfilledOrders(self.id);
                }

            }
        }

    }

    function distributeLiquidationPenalty(
        Account.Data storage self,
        Account.Data storage liquidatorAccount,
        uint256 liquidationPenalty,
        address token,
        uint128 bidSubmissionKeeperId
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        Account.Data storage insuranceFundAccount = Account.exists(collateralPool.insuranceFundConfig.accountId);
        Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);

        uint256 insuranceFundReward = mulUDxUint(
            collateralPool.insuranceFundConfig.liquidationFee,
            liquidationPenalty
        );

        // todo: check whether we should use net deposits or free collateral (ie initialDelta)
        int256 backstopLpNetDepositsInUSD = backstopLpAccount.getMarginInfoByBubble(address(0)).collateralInfo.netDeposits;

        uint256 backstopLPReward = 0;
        if (
            backstopLpNetDepositsInUSD > 0 && 
            backstopLpNetDepositsInUSD.toUint() > collateralPool.backstopLPConfig.minNetDepositThresholdInUSD
        ) {
            backstopLPReward = mulUDxUint(
                collateralPool.backstopLPConfig.liquidationFee,
                liquidationPenalty
            );
        }

        uint256 keeperReward = 0;
        if (bidSubmissionKeeperId != 0) {
            keeperReward = mulUDxUint(
                collateralPool.riskConfig.liquidationConfiguration.bidKeeperFee,
                liquidationPenalty
            );
        }

        uint256 liquidatorReward = liquidationPenalty - insuranceFundReward - backstopLPReward - keeperReward;

        self.updateNetCollateralDeposits(token, -liquidationPenalty.toInt());
        insuranceFundAccount.updateNetCollateralDeposits(token, insuranceFundReward.toInt());
        backstopLpAccount.updateNetCollateralDeposits(token, backstopLPReward.toInt());
        liquidatorAccount.updateNetCollateralDeposits(token, liquidatorReward.toInt());

        if (keeperReward > 0) {
            Account.Data storage keeperAccount = Account.exists(bidSubmissionKeeperId);
            keeperAccount.updateNetCollateralDeposits(token, keeperReward.toInt());
        }
    }

    function computeDutchLiquidationPenaltyParameter(Account.Data storage self) internal view returns (UD60x18) {
        // todo: implement
        return UD60x18.wrap(10e17);
    }

    function executeTopRankedLiquidationBid(
        Account.Data storage self,
        address queueQuoteToken,
        uint128 bidSubmissionKeeperId
    ) internal {
        // revert if the account has any unfilled orders
        self.hasUnfilledOrders();

        // revert if the account is not below the liquidation margin requirement
        isBelowLMCheck(self, address(0));

        Account.LiquidationBidPriorityQueues storage liquidationBidPriorityQueues =
        self.liquidationBidPriorityQueuesPerBubble[queueQuoteToken];

        if (block.timestamp > liquidationBidPriorityQueues.latestQueueEndTimestamp) {
            // the latest queue has expired, hence we cannot execute its top ranked liquidation bid
            revert AccountLiquidation.LiquidationBidPriorityQueueExpired(
                liquidationBidPriorityQueues.latestQueueId,
                liquidationBidPriorityQueues.latestQueueEndTimestamp
            );
        }

        // extract top ranked order

        LiquidationBidPriorityQueue.LiquidationBid memory topRankedLiquidationBid = liquidationBidPriorityQueues
        .priorityQueues[
        liquidationBidPriorityQueues.latestQueueId
        ].topBid();

        (bool success, bytes memory reason) = address(this).call(abi.encodeWithSignature(
            "executeLiquidationBid(uint128, uint128, LiquidationBidPriorityQueue.LiquidationBid memory)",
            self.id, bidSubmissionKeeperId, topRankedLiquidationBid));

        // dequeue top bid it's successfully executed or not

        liquidationBidPriorityQueues.priorityQueues[
        liquidationBidPriorityQueues.latestQueueId
        ].dequeue();
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
        isBelowLMCheck(self, address(0));

        // todo: revert if below insolvency

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        collateralPoolsCheck(self.getCollateralPool().id, liquidatorAccount);

        Market.Data storage market = Market.exists(marketId);

        Account.LiquidationBidPriorityQueues storage liquidationBidPriorityQueues =
        self.liquidationBidPriorityQueuesPerBubble[market.quoteToken];

        // revert if the account is above dutch margin requirement & the liquidation bid queue is not empty

        bool isAboveDutch = self.getMarginInfoByBubble(address(0)).dutchDelta > 0;

        if (
            liquidationBidPriorityQueues.priorityQueues
            [liquidationBidPriorityQueues.latestQueueId].ranks.length > 0 && isAboveDutch) {
            revert AccountIsAboveDutchAndLiquidationBidQueueIsNotEmpty(
                self.id
            );
        }

        UD60x18 liquidationPenaltyParameter = self.computeDutchLiquidationPenaltyParameter();

        int256 lmDeltaBeforeLiquidation = self.getMarginInfoByBubble(market.quoteToken).liquidationDelta;

        market.executeLiquidationOrder(
            self.id,
            liquidatorAccountId,
            inputs
        );

        int256 lmDeltaChange =
        self.getMarginInfoByBubble(market.quoteToken).liquidationDelta - lmDeltaBeforeLiquidation;

        if (lmDeltaChange < 0) {
            revert LiquidationCausedNegativeLMDeltaChange(self.id, lmDeltaChange);
        }

        distributeLiquidationPenalty(
            self,
            liquidatorAccount,
            mulUDxUint(
                liquidationPenaltyParameter,
                lmDeltaChange.toUint()
            ),
            market.quoteToken,
            0);

        liquidatorAccount.imCheck(address(0));

    }


    function executeBackstopLiquidation(
        Account.Data storage self,
        uint128 liquidatorAccountId,
        address quoteToken,
        LiquidationOrder[] memory backstopLPLiquidationOrders
    ) internal {
        self.hasUnfilledOrders();

        // revert if account is not below adl margin requirement
        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));

        if (marginInfo.adlDelta > 0) {
            revert AccountNotBelowADL(self.id, marginInfo);
        }

        // todo: layer in backstop lp & keeper rewards
        // todo: make sure backstop lp capacity is exhausted before proceeding to adl

        (bool _isInsolvent, int256 marginBalance) = isInsolvent(self, quoteToken);

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        uint256 shortfall = 0;

        if (!_isInsolvent) {

            Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);

            // execute backstop lp liquidation orders
            for (uint256 i = 0; i < backstopLPLiquidationOrders.length; i++) {
                LiquidationOrder memory liquidationOrder = backstopLPLiquidationOrders[i];
                Market.Data storage market = Market.exists(liquidationOrder.marketId);
                market.executeLiquidationOrder(
                    self.id,
                    collateralPool.backstopLPConfig.accountId,
                    liquidationOrder.inputs
                );
            }

            backstopLpAccount.imCheck(address(0));

        } else {
            Account.Data storage insuranceFundAccount = Account.exists(collateralPool.insuranceFundConfig.accountId);
            int256 insuranceFundCoverAvailable = insuranceFundAccount.getAccountNetCollateralDeposits(quoteToken)
            - collateralPool.insuranceFundUnderwritings[quoteToken].toInt();

            uint256 insuranceFundDebit = (-marginBalance).toUint();
            if (insuranceFundCoverAvailable + marginBalance < 0) {
                shortfall = (marginBalance-insuranceFundCoverAvailable).toUint();
                insuranceFundDebit = insuranceFundCoverAvailable > 0 ? (-insuranceFundCoverAvailable).toUint() : 0;
            }
            collateralPool.updateInsuranceFundUnderwritings(quoteToken, insuranceFundDebit);
        }

        // execute adl orders (bankruptcy price is calculated in the market manager)

        uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
        for (uint256 j = 0; j < markets.length; j++) {
            uint128 marketId = markets[j].to128();
            Market.exists(marketId).executeADLOrder(
                self.id,
                100, // todo: replace
                10 // todo: replace
            );
        }


    }


}

