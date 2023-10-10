/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/*
TODOs
    - implement rank calculation
*/


import {AccountAutoExchange} from "./AccountAutoExchange.sol";
import {Account} from "../../storage/Account.sol";
import {Market} from "../../storage/Market.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";
import {LiquidationBidPriorityQueue} from "../LiquidationBidPriorityQueue.sol";
import {ILiquidationHook} from "../../interfaces/external/ILiquidationHook.sol";
import { UD60x18, mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {UD60x18, UNIT, ud} from "@prb/math/UD60x18.sol";


import {IERC165} from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

/**
 * @title Object for managing account liquidation utilities
*/
library AccountLiquidation {
    using Account for Account.Data;
    using AccountLiquidation for Account.Data;
    using AccountAutoExchange for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
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
    error LiquidationBidPriorityQueueExpired(address quoteToken, uint256 queueId, uint256 queueEndTimestamp);

    /**
      * @dev Thrown when attempting to submit into a queue that is full
     */
    error LiquidationBidPriorityQueueOverflow(address quoteToken, uint256 queueId, uint256 queueEndTimestamp, uint256 queueLength);

    /**
      * @dev Thrown when attempting to submit a liquidation bid where number of markets and bytes inputs don't match
     */
    error LiquidationBidMarketIdsAndInputsLengthMismatch(uint256 marketIdsLength, uint256 inputsLength);

    /**
      * @dev Thrown when attempting to submit a liquidation bid where the number of orders exceeds the maximum allowed
     */
    error LiquidationBidOrdersOverflow(uint256 ordersLength, uint256 maxOrders);

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

    /**
     * @dev Thrown when an incorrect hook address is used within a liquidation bid
     * @param liquidationBid Submitted liquidation bid
     */
    error IncorrectLiquidationBidHookAddress(LiquidationBidPriorityQueue.LiquidationBid liquidationBid);

    /**
     * @dev Thrown when solvency is queried across bubbles (collateral type is address(0))
     */
    error CannotComputeSolvencyAcrossBubbles();

    struct LiquidationOrder {
        uint128 marketId;
        bytes inputs;
    }

    /**
     * @dev Checks if an account is insolvent in a given bubble (assuming auto-exchange is exhausted!!!)
     * and returns the shortfall
     */
    function isInsolvent(Account.Data storage self, address collateralType) private view returns (bool) {
        if (collateralType == address(0)) {
            revert CannotComputeSolvencyAcrossBubbles();
        }

        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(collateralType);
        return marginInfo.rawInfo.rawMarginBalance < 0;
    }

    function validateLiquidationBid(
        Account.Data storage self,
        Account.Data storage liquidatorAccount,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) private view {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        Account.collateralPoolsCheck(collateralPool.id, liquidatorAccount);

        uint256 marketIdsLength = liquidationBid.marketIds.length;
        uint256 inputsLength = liquidationBid.inputs.length;

        if (marketIdsLength != inputsLength) {
            revert LiquidationBidMarketIdsAndInputsLengthMismatch(marketIdsLength, inputsLength);
        }

        if (marketIdsLength > collateralPool.riskConfig.liquidationConfiguration.maxOrdersInBid) {
            revert LiquidationBidOrdersOverflow(marketIdsLength,
                collateralPool.riskConfig.liquidationConfiguration.maxOrdersInBid);
        }

        if (
            liquidationBid.hookAddress != address(0) && 
            !IERC165(liquidationBid.hookAddress).supportsInterface(type(ILiquidationHook).interfaceId)
        ) {
            revert IncorrectLiquidationBidHookAddress(liquidationBid);
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
                liquidationBid.quoteToken,
                liquidationBidPriorityQueues.latestQueueId,
                liquidationBidPriorityQueues.latestQueueEndTimestamp,
                liquidationBidPriorityQueues.priorityQueues
                [liquidationBidPriorityQueues.latestQueueId].ranks.length
            );
        }

        liquidatorAccount.imCheck();

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

        Account.collateralPoolsCheck(collateralPool.id, liquidatorAccount);

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

        int256 backstopLpFreeCollateralInUSD = backstopLpAccount.getMarginInfoByBubble(address(0)).initialDelta;

        uint256 backstopLPReward = 0;
        if (
            backstopLpFreeCollateralInUSD > 0 && 
            backstopLpFreeCollateralInUSD.toUint() > collateralPool.backstopLPConfig.minNetDepositThresholdInUSD
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

    function computeDutchHealth(Account.Data storage self) internal view returns (UD60x18) {
        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));
        // adl health info values are in USD (and therefore represented with 18 decimals)
        UD60x18 health = ud(marginInfo.rawInfo.rawMarginBalance.toUint()).div(
            ud(marginInfo.rawInfo.rawLiquidationMarginRequirement)
        );
        if (health.gt(UNIT)) {
            health = UNIT;
        }
        return health;
    }

    function computeDutchLiquidationPenaltyParameter(Account.Data storage self) internal view returns (UD60x18) {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        UD60x18 dMin = collateralPool.riskConfig.dutchConfiguration.dMin;
        UD60x18 dSlope = collateralPool.riskConfig.dutchConfiguration.dSlope;
        UD60x18 health = self.computeDutchHealth();

        UD60x18 dDutch = dMin.add(UNIT.sub(health).mul(dSlope));
        if (dDutch.gt(UNIT)) {
            dDutch = UNIT;
        }

        return dDutch;
    }

    function executeTopRankedLiquidationBid(
        Account.Data storage self,
        address queueQuoteToken,
        uint128 bidSubmissionKeeperId
    ) internal {
        // revert if the account has any unfilled orders
        self.hasUnfilledOrders();

        // revert if account is not between adl and liquidation margin requirement
        self.betweenAdlAndLmCheck();

        Account.LiquidationBidPriorityQueues storage liquidationBidPriorityQueues =
        self.liquidationBidPriorityQueuesPerBubble[queueQuoteToken];

        if (block.timestamp > liquidationBidPriorityQueues.latestQueueEndTimestamp) {
            // the latest queue has expired, hence we cannot execute its top ranked liquidation bid
            revert AccountLiquidation.LiquidationBidPriorityQueueExpired(
                queueQuoteToken,
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
        // todo: enable pausability on maturity level

        // revert if account has unfilled orders that are not closed yet
        self.hasUnfilledOrders();

        // revert if account is not between adl and liquidation margin requirement
        self.betweenAdlAndLmCheck();

        // grab the liquidator account
        Account.Data storage liquidatorAccount = Account.exists(liquidatorAccountId);

        Account.collateralPoolsCheck(self.getCollateralPool().id, liquidatorAccount);

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

        liquidatorAccount.imCheck();

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

        bool _isInsolvent = isInsolvent(self, quoteToken);
        if (!_isInsolvent) {
            executeSolventBackstopLiquidation(self, liquidatorAccountId, quoteToken, backstopLPLiquidationOrders);
        } else {
            executeInsolventADLLiquidation(self, liquidatorAccountId, quoteToken, marginInfo);
        }
    }

    function executeSolventBackstopLiquidation(
        Account.Data storage self,
        uint128 liquidatorAccountId,
        address quoteToken,
        LiquidationOrder[] memory backstopLPLiquidationOrders
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

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

        bool leftExposure = false;

        uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
        for (uint256 i = 0; i < markets.length && !leftExposure; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            (int256[] memory filledExposures,) =
                market.getAccountTakerAndMakerExposures(self.id, collateralPool.riskMatrixDims[market.riskBlockId]);

            for (uint256 j = 0; j < filledExposures.length && !leftExposure; j++) {
                // no unfilled exposure here, so lower and upper are the same
                if (filledExposures[j] > 0) {
                    leftExposure = true;
                }
            }
        }

        if (leftExposure) {
            backstopLpAccount.betweenImAndImBufferCheck();

            for (uint256 i = 0; i < markets.length; i++) {
                uint128 marketId = markets[i].to128();
                Market.exists(marketId).executeADLOrder({
                    liquidatableAccountId: self.id,
                    adlNegativeUpnl: true,
                    adlPositiveUpnl: true,
                    totalUnrealizedLossQuote: 0,
                    realBalanceAndIF: 0
                });

                // todo: shouldn't we update trackers here?
            }
        }
    }


    function executeInsolventADLLiquidation(
        Account.Data storage self,
        uint128 liquidatorAccountId,
        address quoteToken,
        Account.MarginInfo memory marginInfo
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        // adl maturities with positive upnl at market price
        uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
        for (uint256 i = 0; i < markets.length; i++) {
            uint128 marketId = markets[i].to128();
            Market.exists(marketId).executeADLOrder({
                liquidatableAccountId: self.id,
                adlNegativeUpnl: false,
                adlPositiveUpnl: true,
                totalUnrealizedLossQuote: 0,
                realBalanceAndIF: 0
            });

            // todo: shouldn't we update trackers here?
        }

        Account.Data storage insuranceFundAccount = 
            Account.exists(collateralPool.insuranceFundConfig.accountId);
        int256 insuranceFundCoverAvailable = 
            insuranceFundAccount.getAccountNetCollateralDeposits(quoteToken) - 
                collateralPool.insuranceFundUnderwritings[quoteToken].toInt();

        if (insuranceFundCoverAvailable + marginInfo.collateralInfo.marginBalance > 0) {
            collateralPool.updateInsuranceFundUnderwritings(quoteToken, (-marginInfo.collateralInfo.marginBalance).toUint());
            
            // adl maturities with negative upnl at market price
            for (uint256 i = 0; i < markets.length; i++) {
                uint128 marketId = markets[i].to128();
                Market.exists(marketId).executeADLOrder({
                    liquidatableAccountId: self.id,
                    adlNegativeUpnl: true,
                    adlPositiveUpnl: false,
                    totalUnrealizedLossQuote: 0,
                    realBalanceAndIF: 0
                });

                // todo: shouldn't we update trackers here?
                // todo: shall we query active markets again before this loop?
            }
        } else {
            // note: insuranceFundCoverAvailable should never be negative
            uint256 insuranceFundDebit = insuranceFundCoverAvailable > 0 ? (-insuranceFundCoverAvailable).toUint() : 0;
            collateralPool.updateInsuranceFundUnderwritings(quoteToken, insuranceFundDebit);

            // gather pending funds from auto-exchange
            uint256 pendingAutoExchangeFunds = 0;
            if (self.isEligibleForAutoExchange(quoteToken)) {
                address[] memory collateralTokens = 
                    CollateralConfiguration.exists(collateralPool.id, address(0)).childTokens.values();

                for (uint256 i = 0; i < collateralTokens.length; i++) {
                    address collateralType = collateralTokens[i];
                    (, , uint256 quoteDelta) = self.calculateAvailableCollateralToAutoExchange(
                        collateralType,
                        quoteToken,
                        0 // todo: cannot come up with this value here, sync with @arturbeg
                    );

                    pendingAutoExchangeFunds += quoteDelta;
                }                
            }

            // compute total unrealized loss
            uint256 totalUnrealizedLossQuote = 0;
            for (uint256 i = 0; i < markets.length; i++) {
                    uint128 marketId = markets[i].to128();
                Market.Data storage market = Market.exists(marketId);

                Account.PnLComponents memory pnlComponents = market.getAccountPnLComponents(self.id);
                // upnl here is negative since all positive upnl exposures were adl-ed at market price
                totalUnrealizedLossQuote += (-pnlComponents.unrealizedPnL).toUint();

                // todo: shouldn't we update trackers here?
                // todo: shall we query active markets again before this loop?
            }

            // adl maturities with negative upnl at bankruptcy price
            for (uint256 i = 0; i < markets.length; i++) {
                uint128 marketId = markets[i].to128();
                Market.exists(marketId).executeADLOrder({
                    liquidatableAccountId: self.id,
                    adlNegativeUpnl: true,
                    adlPositiveUpnl: false,
                    totalUnrealizedLossQuote: totalUnrealizedLossQuote,
                    realBalanceAndIF: 
                        marginInfo.collateralInfo.realBalance + 
                        pendingAutoExchangeFunds.toInt() + 
                        insuranceFundDebit.toInt()
                });

                // todo: shouldn't we update trackers here?
                // todo: shall we query active markets again before this loop?
            }
        }
    }
}

