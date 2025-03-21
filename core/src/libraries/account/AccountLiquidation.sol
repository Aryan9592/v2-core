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

import { MarginInfo, PnLComponents, CollateralInfo } from "../DataTypes.sol";
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
import {UD60x18, UNIT, ud, ZERO} from "@prb/math/UD60x18.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

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
    error AccountNotBetweenMmrAndLm(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when account is not below the adl margin requirement
     */
    error AccountNotBelowADL(uint128 accountId, MarginInfo marginInfo);

    /**
     * @dev Thrown when account is not below the maintenance margin requirement
     */
    error AccountNotBelowMMR(uint128 accountId, MarginInfo marginInfo);


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
     * @dev Thrown when attempting to submit a liquidation bid which contains an order for a non-active market
     */
    error NonActiveMarketInLiquidationBid(uint128 liquidatableAccountId, LiquidationBidPriorityQueue.LiquidationBid liquidationBid);

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
    error LiquidationCausedNegativeLMDeltaChange(uint128 accountId, uint256 lmrBefore, uint256 lmrAfter);

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

    /**
     * Thrown when a liquidation bid is submitted with a liquidator reward higher than 1
     */
    error LiquidationBidRewardOverflow(uint128 liquidatableAccountId, LiquidationBidPriorityQueue.LiquidationBid liquidationBid);

    /**
     * Thrown when an ADL propagation is attempted but the insurance fund is unable to cover the keeper fee,
     * @param accountId The account id for which the ADL propagation was attempted
     * @param insuranceFundCoverAvailable The available IF cover
     * @param keeperFee The flat keeper fee that must be awarded.
     */
    error InsufficientInsuranceFundToCoverADLPropagationReward(
        uint128 accountId,
        uint256 insuranceFundCoverAvailable, 
        uint256 keeperFee
    );

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

        MarginInfo memory marginInfo = self.getMarginInfoByBubble(collateralType);
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

        if (liquidationBid.liquidatorRewardParameter.gt(UNIT)) {
            revert LiquidationBidRewardOverflow(self.id, liquidationBid);
        }

        for (uint256 i = 0; i < marketIdsLength; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            Market.Data storage market = Market.exists(marketId);
            if (market.quoteToken != liquidationBid.quoteToken) {
                revert LiquidationBidQuoteTokenMismatch(liquidationBid.quoteToken, market.quoteToken);
            }
            if (!self.activeMarketsPerQuoteToken[liquidationBid.quoteToken].contains(marketId)) {
                revert NonActiveMarketInLiquidationBid(self.id, liquidationBid);
            }
            market.validateLiquidationOrder(
                self.id,
                liquidatorAccount.id,
                liquidationBid.inputs[i]
            );
        }

    }

    function computeLiquidationBidRank(
        Account.Data storage self,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) private returns (uint256) {
        UD60x18 accPSlippageNumerator;
        UD60x18 accPSlippageDenominator;
        for (uint256 i = 0; i < liquidationBid.marketIds.length; i++) {
            uint128 marketId = liquidationBid.marketIds[i];
            if (!self.activeMarketsPerQuoteToken[liquidationBid.quoteToken].contains(marketId)) {
                revert NonActiveMarketInLiquidationBid(self.id, liquidationBid);
            }

            Market.Data storage market = Market.exists(marketId);
            (int256 annualizedExposureWad, UD60x18 pSlippage) 
                = market.getAnnualizedExposureWadAndPSlippage(marketId, liquidationBid.inputs[i]);

            UD60x18 absAnnualizedExposure = ud(SignedMath.abs(annualizedExposureWad));
            accPSlippageNumerator = accPSlippageNumerator.add(absAnnualizedExposure.mul(pSlippage));
            accPSlippageDenominator = accPSlippageDenominator.add(absAnnualizedExposure);
        }

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        UD60x18 wRank = collateralPool.riskConfig.liquidationConfiguration.wRank;

        // rank = w * (1 - d) + (1 - w) * accPSlippageNumerator / accPSlippageDenominator;
        UD60x18 rank = wRank.mul(UNIT.sub(liquidationBid.liquidatorRewardParameter)).add(
            UNIT.sub(wRank).mul(accPSlippageNumerator.div(accPSlippageDenominator))
        );

        return rank.unwrap();
    }

    function submitLiquidationBid(
        Account.Data storage self,
        LiquidationBidPriorityQueue.LiquidationBid memory liquidationBid
    ) internal {

        MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));

        if (!(marginInfo.maintenanceDelta < 0 && marginInfo.liquidationDelta > 0)) {
            revert AccountNotBetweenMmrAndLm(self.id, marginInfo);
        }

        Account.Data storage liquidatorAccount = Account.loadAccountAndValidatePermission(
            liquidationBid.liquidatorAccountId,
            Account.ADMIN_PERMISSION,
            msg.sender
        );

        validateLiquidationBid(self, liquidatorAccount, liquidationBid);

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        CollateralConfiguration.Data storage collateralConfig = CollateralConfiguration.exists(
            collateralPool.id, 
            liquidationBid.quoteToken
        );

        self.updateNetCollateralDeposits({
            collateralType: liquidationBid.quoteToken, 
            amount: collateralConfig.baseConfig.bidSubmissionFee.toInt()
        });
        collateralPool.updateInsuranceFundBalance(
            liquidationBid.quoteToken, 
            collateralConfig.baseConfig.bidSubmissionFee
        );

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

        uint256 liquidationBidRank = computeLiquidationBidRank(self, liquidationBid);
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

        MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));

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
            uint256 rawLMRBefore = self.getMarginInfoByBubble(quoteToken).rawInfo.rawLiquidationMarginRequirement;
            uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
            for (uint256 j = 0; j < markets.length; j++) {
                uint128 marketId = markets[j].to128();
                Market.exists(marketId).closeAllUnfilledOrders(self.id);
            }
            uint256 rawLMRAfter = self.getMarginInfoByBubble(quoteToken).rawInfo.rawLiquidationMarginRequirement;

            if (rawLMRAfter > rawLMRBefore) {
                revert LiquidationCausedNegativeLMDeltaChange(self.id, rawLMRBefore, rawLMRAfter);
            }

            distributeLiquidationPenalty(
                self,
                liquidatorAccount,
                mulUDxUint(
                    collateralPool.riskConfig.liquidationConfiguration.unfilledPenaltyParameter,
                    rawLMRBefore - rawLMRAfter
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
        Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);

        uint256 insuranceFundReward = mulUDxUint(
            collateralPool.insuranceFundConfig.liquidationFee,
            liquidationPenalty
        );

        int256 backstopLpFreeCollateralInUSD = backstopLpAccount.getMarginInfoByBubble(address(0)).initialDelta;

        uint256 backstopLPReward = 0;
        if (
            backstopLpFreeCollateralInUSD > 0 && 
            backstopLpFreeCollateralInUSD.toUint() > collateralPool.backstopLPConfig.minFreeCollateralThresholdInUSD
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
        collateralPool.updateInsuranceFundBalance(token, insuranceFundReward);
        backstopLpAccount.updateNetCollateralDeposits(token, backstopLPReward.toInt());
        liquidatorAccount.updateNetCollateralDeposits(token, liquidatorReward.toInt());

        if (keeperReward > 0) {
            Account.Data storage keeperAccount = Account.exists(bidSubmissionKeeperId);
            keeperAccount.updateNetCollateralDeposits(token, keeperReward.toInt());
        }
    }

    function distributeBackstopAdlRewards(
        Account.Data storage self,
        Account.Data storage keeperAccount,
        address token,
        uint256 deltaLMR,
        UD60x18 backstopRewardFee,
        UD60x18 keeperRewardFee
    ) internal returns (uint256 totalRewards) {
        if (backstopRewardFee.gt(ZERO)) {
            CollateralPool.Data storage collateralPool = self.getCollateralPool();
            Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);

            uint256 backstopReward = mulUDxUint(backstopRewardFee, deltaLMR);
            backstopLpAccount.updateNetCollateralDeposits(token, backstopReward.toInt());
            totalRewards += backstopReward;
        }

        if (keeperRewardFee.gt(ZERO)) {
            uint256 keeperReward = mulUDxUint(keeperRewardFee, deltaLMR);
            keeperAccount.updateNetCollateralDeposits(token, keeperReward.toInt());
            totalRewards += keeperReward;
        }
        
        self.updateNetCollateralDeposits(token, -totalRewards.toInt());
    }

    function computeDutchHealth(Account.Data storage self) internal view returns (UD60x18) {
        MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));
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
        LiquidationBidPriorityQueue.LiquidationBid memory topRankedLiquidationBid = 
            liquidationBidPriorityQueues.priorityQueues[
                liquidationBidPriorityQueues.latestQueueId
            ].topBid();

        (bool success, bytes memory reason) = 
            address(this).call(
                abi.encodeWithSignature(
                    "executeLiquidationBid(uint128, uint128, LiquidationBidPriorityQueue.LiquidationBid memory)",
                    self.id, 
                    bidSubmissionKeeperId, 
                    topRankedLiquidationBid
                )
            );

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

        uint256 rawLMRBefore = self.getMarginInfoByBubble(market.quoteToken).rawInfo.rawLiquidationMarginRequirement;

        market.executeLiquidationOrder(
            self.id,
            liquidatorAccountId,
            inputs
        );

        uint256 rawLMRAfter = self.getMarginInfoByBubble(market.quoteToken).rawInfo.rawLiquidationMarginRequirement;

        if (rawLMRAfter > rawLMRBefore) {
            revert LiquidationCausedNegativeLMDeltaChange(self.id, rawLMRBefore, rawLMRAfter);
        }

        distributeLiquidationPenalty(
            self,
            liquidatorAccount,
            mulUDxUint(
                liquidationPenaltyParameter,
                rawLMRBefore - rawLMRAfter
            ),
            market.quoteToken,
            0
        );

        liquidatorAccount.imCheck();
    }


    function executeBackstopLiquidation(
        Account.Data storage self,
        uint128 keeperAccountId,
        address quoteToken,
        LiquidationOrder[] memory backstopLPLiquidationOrders
    ) internal {
        self.hasUnfilledOrders();

        // revert if account is not below adl margin requirement
        MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));
        if (marginInfo.adlDelta > 0) {
            revert AccountNotBelowADL(self.id, marginInfo);
        }

        Account.collateralPoolsCheck(self.getCollateralPool().id, Account.exists(keeperAccountId));

        bool _isInsolvent = isInsolvent(self, quoteToken);
        if (!_isInsolvent) {
            executeSolventBackstopLiquidation(self, keeperAccountId, quoteToken, backstopLPLiquidationOrders);
        } else {
            executeInsolventADLLiquidation(self, keeperAccountId, quoteToken, marginInfo);
        }
    }

    struct SolventBackstopLiquidationVars {
        uint256 rawLMRBeforeBackstop;
        uint256 rawLMRAfterBackstop;
    }

    function executeSolventBackstopLiquidation(
        Account.Data storage self,
        uint128 keeperAccountId,
        address quoteToken,
        LiquidationOrder[] memory backstopLPLiquidationOrders
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        SolventBackstopLiquidationVars memory vars;

        vars.rawLMRBeforeBackstop = self.getMarginInfoByBubble(
            quoteToken
        ).rawInfo.rawLiquidationMarginRequirement;

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

        vars.rawLMRAfterBackstop = self.getMarginInfoByBubble(
            quoteToken
        ).rawInfo.rawLiquidationMarginRequirement;
        if (vars.rawLMRAfterBackstop > vars.rawLMRBeforeBackstop) {
            revert LiquidationCausedNegativeLMDeltaChange(self.id, vars.rawLMRBeforeBackstop, vars.rawLMRAfterBackstop);
        }

        self.distributeBackstopAdlRewards({
            keeperAccount: Account.exists(keeperAccountId),
            token: quoteToken,
            deltaLMR: vars.rawLMRBeforeBackstop - vars.rawLMRAfterBackstop,
            backstopRewardFee: UNIT.sub(collateralPool.riskConfig.liquidationConfiguration.backstopKeeperFee),
            keeperRewardFee: collateralPool.riskConfig.liquidationConfiguration.backstopKeeperFee
        });

        bool leftExposure = false;

        uint256[] memory markets = self.activeMarketsPerQuoteToken[quoteToken].values();
        for (uint256 i = 0; i < markets.length && !leftExposure; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            int256[] memory filledExposures =
                market.getAccountTakerExposures(self.id, collateralPool.riskMatrixDims[market.riskBlockId]);

            for (uint256 j = 0; j < filledExposures.length && !leftExposure; j++) {
                // no unfilled exposure here, so lower and upper are the same
                if (filledExposures[j] > 0) {
                    leftExposure = true;
                }
            }
        }

        if (leftExposure) {
            Account.Data storage backstopLpAccount = Account.exists(collateralPool.backstopLPConfig.accountId);
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
            }

            // all exposure will be ADL-ed, so LMR will be 0 afterwards
            self.distributeBackstopAdlRewards({
                keeperAccount: Account.exists(keeperAccountId),
                token: quoteToken,
                deltaLMR: vars.rawLMRAfterBackstop,
                backstopRewardFee: ZERO,
                keeperRewardFee: collateralPool.riskConfig.liquidationConfiguration.adlExecutionKeeperFee
            });
        }
    }


    function executeInsolventADLLiquidation(
        Account.Data storage self,
        uint128 keeperAccountId,
        address quoteToken,
        MarginInfo memory marginInfo
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        MarginInfo memory quoteMarginInfo = self.getMarginInfoByBubble(quoteToken);

        // all exposure will be ADL-ed, so LMR will be 0 afterwards
        uint256 totalRewards = self.distributeBackstopAdlRewards({
            keeperAccount: Account.exists(keeperAccountId),
            token: quoteToken,
            deltaLMR: quoteMarginInfo.rawInfo.rawLiquidationMarginRequirement,
            backstopRewardFee: ZERO,
            keeperRewardFee: collateralPool.riskConfig.liquidationConfiguration.adlExecutionKeeperFee
        });

        // update collateral info after rewards distribution
        quoteMarginInfo.collateralInfo = CollateralInfo({
            netDeposits: quoteMarginInfo.collateralInfo.netDeposits -= totalRewards.toInt(),
            realBalance: quoteMarginInfo.collateralInfo.realBalance -= totalRewards.toInt(),
            marginBalance: quoteMarginInfo.collateralInfo.marginBalance -= totalRewards.toInt()
        });

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
        }

        uint256 insuranceFundCoverAvailable = collateralPool.getAvailableInsuranceFundCover({
            quoteToken: quoteToken, 
            preserveMinThreshold: true
        });

        if (insuranceFundCoverAvailable.toInt() + quoteMarginInfo.collateralInfo.marginBalance > 0) {
            collateralPool.updateInsuranceFundUnderwritings(quoteToken, (-quoteMarginInfo.collateralInfo.marginBalance).toUint());
            
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
            }
        } else {
            int256 realBalanceAndIF = quoteMarginInfo.collateralInfo.realBalance;

            collateralPool.updateInsuranceFundUnderwritings(quoteToken, insuranceFundCoverAvailable);
            realBalanceAndIF += insuranceFundCoverAvailable.toInt();

            // gather pending funds from auto-exchange
            realBalanceAndIF += self.getPendingAutoExchangeFunds(quoteToken).toInt();

            // compute total unrealized loss
            uint256 totalUnrealizedLossQuote = 0;
            for (uint256 i = 0; i < markets.length; i++) {
                uint128 marketId = markets[i].to128();
                Market.Data storage market = Market.exists(marketId);

                PnLComponents memory pnlComponents = market.getAccountPnLComponents(self.id);
                // upnl here is negative since all positive upnl exposures were adl-ed at market price
                totalUnrealizedLossQuote += (-pnlComponents.unrealizedPnL).toUint();
            }

            // adl maturities with negative upnl at bankruptcy price
            for (uint256 i = 0; i < markets.length; i++) {
                uint128 marketId = markets[i].to128();
                Market.exists(marketId).executeADLOrder({
                    liquidatableAccountId: self.id,
                    adlNegativeUpnl: true,
                    adlPositiveUpnl: false,
                    totalUnrealizedLossQuote: totalUnrealizedLossQuote,
                    realBalanceAndIF: realBalanceAndIF
                });
            }
        }
    }

    // todo: check function after auto-exchange is addressed
    function getPendingAutoExchangeFunds(
        Account.Data storage self,
        address quoteToken
    ) internal returns (uint256 pendingAutoExchangeFunds) {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        // todo: check correctness here after auto-exchange is addressed
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
    }

    function propagateADLOrder(
        Account.Data storage self,
        uint128 marketId, 
        uint128 keeperAccountId, 
        bytes memory inputs
    ) internal {
        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        Market.Data storage market = Market.exists(marketId);
        Account.Data storage keeperAccount = Account.exists(keeperAccountId);

        Account.collateralPoolsCheck(collateralPool.id, keeperAccount);

        uint256 insuranceFundCoverAvailable = collateralPool.getAvailableInsuranceFundCover({
            quoteToken: market.quoteToken, 
            preserveMinThreshold: false
        });

        CollateralConfiguration.Data storage collateralConfiguration = 
            CollateralConfiguration.exists(collateralPool.id, market.quoteToken);
        if (insuranceFundCoverAvailable < collateralConfiguration.baseConfig.adlPropagationKeeperFee) {
            revert InsufficientInsuranceFundToCoverADLPropagationReward(
                self.id,
                insuranceFundCoverAvailable, 
                collateralConfiguration.baseConfig.adlPropagationKeeperFee
            );
        }

        market.propagateADLOrder(self.id, inputs);

        collateralPool.updateInsuranceFundUnderwritings(
            market.quoteToken, 
            collateralConfiguration.baseConfig.adlPropagationKeeperFee
        );
        keeperAccount.updateNetCollateralDeposits(
            market.quoteToken,
            collateralConfiguration.baseConfig.adlPropagationKeeperFee.toInt()
        );
    }
}

