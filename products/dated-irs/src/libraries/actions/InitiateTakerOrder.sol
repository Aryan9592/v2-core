/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { PositionBalances, TakerOrderParams } from "../DataTypes.sol";

import { Portfolio } from "../../storage/Portfolio.sol";
import { Market } from "../../storage/Market.sol";

import { IPool } from "../../interfaces/IPool.sol";
import { ExposureHelpers } from "../ExposureHelpers.sol";

import { UD60x18, mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SignedMath } from "oz/utils/math/SignedMath.sol";

/**
 * @title Library for taker orders logic.
 */
library InitiateTakerOrder {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @notice Emitted when a taker order of the account token with id `accountId` is initiated.
     * @param params The parameters of the taker order.
     * @param tokenDeltas The executed token amounts of the order.
     * @param annualizedNotionalAmount The annualized base of the order.
     * @param blockTimestamp The current block timestamp.
     */
    event TakerOrder(
        TakerOrderParams params, PositionBalances tokenDeltas, int256 annualizedNotionalAmount, uint256 blockTimestamp
    );

    /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool linked to this
     * market manager
     * @dev Initially a single pool is connected to a single market singleton, however, that doesn't need to be the case
     * in the future
     * params accountId Id of the account that wants to initiate a taker order
     * params marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * params maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * params priceLimit The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     * params baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction
     * depending on
     * sign
     */
    function initiateTakerOrder(TakerOrderParams memory params)
        internal
        returns (PositionBalances memory tokenDeltas, uint256 exchangeFee, uint256 protocolFee)
    {
        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);
        UD60x18 exposureFactor = market.exposureFactor();

        UD60x18 markPrice = ExposureHelpers.computeTwap(
            params.marketId, params.maturityTimestamp, market.marketConfig.poolAddress, params.baseDelta, exposureFactor
        );

        tokenDeltas = pool.executeDatedTakerOrder(
            params.marketId,
            params.maturityTimestamp,
            params.baseDelta,
            params.priceLimit,
            markPrice,
            market.marketConfig.markPriceBand
        );

        Portfolio.Data storage portfolio = Portfolio.loadOrCreate(params.accountId, params.marketId);
        portfolio.updatePosition(params.maturityTimestamp, tokenDeltas);

        int256 annualizedNotionalAmount =
            ExposureHelpers.baseToAnnualizedExposure(tokenDeltas.base, params.maturityTimestamp, exposureFactor);

        ExposureHelpers.checkPositionSizeLimit(params.accountId, params.marketId, params.maturityTimestamp);

        market.updateOracleStateIfNeeded();

        protocolFee =
            mulUDxUint(market.marketConfig.protocolFeeConfig.atomicTakerFee, SignedMath.abs(annualizedNotionalAmount));

        // todo: calculate exchange fee in the vamm?
        exchangeFee = 0;

        emit TakerOrder(params, tokenDeltas, annualizedNotionalAmount, block.timestamp);
    }
}
