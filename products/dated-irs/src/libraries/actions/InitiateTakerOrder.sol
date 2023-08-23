/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../../storage/MarketManagerConfiguration.sol";
import "../../storage/MarketConfiguration.sol";
import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";
import "../../storage/RateOracleReader.sol";
import "../../storage/Portfolio.sol";
import "./InitiateMakerOrder.sol";
import "../../interfaces/IPool.sol";

/**
 * @title Library for taker orders logic.
 */
library InitiateTakerOrder {
    using Portfolio for Portfolio.Data;
    using RateOracleReader for RateOracleReader.Data;

    struct TakerOrderParams {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmount;
        uint160 priceLimit;
    }

    /**
     * @notice Emitted when a taker order of the account token with id `accountId` is initiated.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param collateralType The address of the collateral.
     * @param executedBaseAmount The executed base amount of the order.
     * @param executedQuoteAmount The executed quote amount of the order.
     * @param annualizedNotionalAmount The annualized base of the order.
     * @param blockTimestamp The current block timestamp.
     */
    event TakerOrder(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        address collateralType,
        int256 executedBaseAmount,
        int256 executedQuoteAmount,
        int256 annualizedNotionalAmount,
        uint256 blockTimestamp
    );

     /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool linked to this market manager
     * @dev Initially a single pool is connected to a single market singleton, however, that doesn't need to be the case in the future
     * params accountId Id of the account that wants to initiate a taker order
     * params marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * params maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * params priceLimit The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     * params baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction depending on
     * sign
     */
    function initiateTakerOrder(TakerOrderParams memory params)
        internal
        returns (int256 executedBaseAmount, int256 executedQuoteAmount, uint256 fee)
    {
        FeatureFlagSupport.ensureEnabledMarket(params.marketId);

        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        // check account access permissions
        IAccountModule(coreProxy).onlyAuthorized(params.accountId, Account.ADMIN_PERMISSION, msg.sender);

        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        // todo: check with @ab if we want it adjusted or not
        UD60x18 markPrice = pool.getAdjustedDatedIRSTwap(
            params.marketId, 
            params.maturityTimestamp, 
            params.baseAmount, 
            market.marketConfig.twapLookbackWindow
        );

        // todo: check there is an active pool with maturityTimestamp requested
        (executedBaseAmount, executedQuoteAmount) =
            pool.executeDatedTakerOrder(
                params.marketId, 
                params.maturityTimestamp, 
                params.baseAmount, 
                params.priceLimit, 
                markPrice, 
                market.marketConfig.markPriceBand
            );

        Portfolio.loadOrCreate(params.accountId, params.marketId).updatePosition(
            params.maturityTimestamp, executedBaseAmount, executedQuoteAmount
        );

        // propagate order
        address quoteToken = MarketConfiguration.load(params.marketId).quoteToken;
        int256 annualizedNotionalAmount = InitiateMakerOrder.getSingleAnnualizedExposure(
            executedBaseAmount, params.marketId, params.maturityTimestamp
        );
        
        fee = IMarketManagerModule(coreProxy).propagateTakerOrder(
            params.accountId,
            params.marketId,
            market.quoteToken,
            annualizedNotionalAmount
        );

        market.updateOracleStateIfNeeded();

        emit TakerOrder(
            params.accountId,
            params.marketId,
            params.maturityTimestamp,
            market.quoteToken,
            executedBaseAmount,
            executedQuoteAmount,
            annualizedNotionalAmount,
            block.timestamp
        );
    }
}
