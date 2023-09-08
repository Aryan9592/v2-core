/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {MarketManagerConfiguration} from "../../storage/MarketManagerConfiguration.sol";
import {IAccountModule} from "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IMarketManagerModule} from "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";
import {Portfolio} from "../../storage/Portfolio.sol";
import {InitiateMakerOrder} from "./InitiateMakerOrder.sol";
import {Market} from "../../storage/Market.sol";
import {IPool} from "../../interfaces/IPool.sol";
import {FeatureFlagSupport} from "../FeatureFlagSupport.sol";
import {ExposureHelpers} from "../ExposureHelpers.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import {DecimalMath} from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

/**
 * @title Library for taker orders logic.
 */
library InitiateTakerOrder {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

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
        returns (
            int256 executedBaseAmount,
            int256 executedQuoteAmount,
            int256 annualizedNotionalAmount
        )
    {
        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        // check account access permissions
        IAccountModule(coreProxy).onlyAuthorized(params.accountId, Account.ADMIN_PERMISSION, msg.sender);

        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        int256 orderSizeWad = DecimalMath.changeDecimals(
            params.baseAmount,
            IERC20(market.quoteToken).decimals(),
            DecimalMath.WAD_DECIMALS
        );
        UD60x18 markPrice = pool.getAdjustedDatedIRSTwap(
            params.marketId, 
            params.maturityTimestamp, 
            orderSizeWad, 
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

        Portfolio.Data storage portfolio = Portfolio.loadOrCreate(params.accountId, params.marketId);
        portfolio.updatePosition(
            params.maturityTimestamp, executedBaseAmount, executedQuoteAmount
        );

        annualizedNotionalAmount = InitiateMakerOrder.getSingleAnnualizedExposure(
            executedBaseAmount, params.marketId, params.maturityTimestamp
        );

        ExposureHelpers.checkPositionSizeLimit(
            params.accountId,
            params.marketId,
            params.maturityTimestamp
        );

        /// @dev if base balance and executed base have the same sign
        /// it means the exposure grew and the delta should be positive.
        /// otherwise, the exposure was reduced and the delta is negative.
        int256 annualizedNotionalDelta = annualizedNotionalAmount > 0 ? 
            -annualizedNotionalAmount : annualizedNotionalAmount;
        if (
            Portfolio.exists(params.accountId, params.marketId)
            .positions[params.maturityTimestamp]
            .baseBalance * executedBaseAmount > 0
        ) {
            annualizedNotionalDelta = -annualizedNotionalDelta;
        }
        ExposureHelpers.checkOpenInterestLimit(
            params.marketId,
            params.maturityTimestamp,
            annualizedNotionalDelta 
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
