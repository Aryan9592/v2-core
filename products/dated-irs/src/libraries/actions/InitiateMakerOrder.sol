/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { PositionBalances, MakerOrderParams } from "../DataTypes.sol";
import { ExposureHelpers } from "../ExposureHelpers.sol";

import { Market } from "../../storage/Market.sol";
import { Portfolio } from "../../storage/Portfolio.sol";

import { IPool } from "../../interfaces/IPool.sol";

import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SignedMath } from "oz/utils/math/SignedMath.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Library for maker orders logic.
 */
library InitiateMakerOrder {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    /**
     * @notice Emitted after a successful mint or burn of liquidity on a given LP position
     * @param params The parameters of the maker order transaction
     * @param blockTimestamp The current block timestamp.
     */
    event MakerOrder(MakerOrderParams params, uint256 blockTimestamp);

    /**
     * @notice Initiates a maker order for a given account by providing or burining liquidity in the given tick range
     * @param params Parameters of the maker order
     */

    function initiateMakerOrder(MakerOrderParams memory params)
        internal
        returns (uint256 exchangeFee, uint256 protocolFee)
    {
        // check if market id is valid + check there is an active pool with maturityTimestamp requested
        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);
        UD60x18 exposureFactor = market.exposureFactor();

        pool.executeDatedMakerOrder(params);

        Portfolio.loadOrCreate(params.accountId, params.marketId).updatePosition(
            params.maturityTimestamp, PositionBalances({ base: 0, quote: 0, extraCashflow: 0 })
        );

        market.updateOracleStateIfNeeded();
        // todo: consider having a separate position size limit check for makers which only considers unfilled
        // orders

        ExposureHelpers.checkPositionSizeLimit(params.accountId, params.marketId, params.maturityTimestamp);

        if (params.baseDelta > 0) {
            int256 annualizedNotionalAmount =
                ExposureHelpers.baseToAnnualizedExposure(params.baseDelta, params.maturityTimestamp, exposureFactor);

            protocolFee = mulUDxUint(
                market.marketConfig.protocolFeeConfig.atomicMakerFee, SignedMath.abs(annualizedNotionalAmount)
            );

            // todo: calculate exchange fee in the vamm?
            exchangeFee = 0;
        }

        emit MakerOrder(params, block.timestamp);
    }
}
