/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../../storage/MarketManagerConfiguration.sol";
import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import "../../interfaces/IPool.sol";
import "../../storage/Portfolio.sol";
import {FeatureFlagSupport} from "../FeatureFlagSupport.sol";
import {IMarketManagerModule} from "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";

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

    struct MakerOrderParams {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    /**
     * @notice Emitted after a successful mint or burn of liquidity on a given LP position
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param sender Address that called the initiate maker order function.
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity added (positive values) or removed (negative values) within the tick range
     * @param blockTimestamp The current block timestamp.
     */
    event MakerOrder(
        uint128 indexed accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 liquidityDelta,
        uint256 blockTimestamp
    );

    /**
     * @notice Initiates a maker order for a given account by providing or burining liquidity in the given tick range
     * param accountId Id of the `Account` with which the lp wants to provide liqudity
     * param marketId Id of the market in which the lp wants to provide liqudiity
     * param maturityTimestamp Timestamp at which a given market matures
     * param tickLower Lower tick of the range order
     * param tickUpper Upper tick of the range order
     * param liquidityDelta Liquidity to add (positive values) or remove (negative values) within the tick range
     */
    function initiateMakerOrder(MakerOrderParams memory params)
        internal
        returns (int256 annualizedNotionalAmount)
    {
        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        // check account access permissions
        IAccountModule(coreProxy).onlyAuthorized(params.accountId, Account.ADMIN_PERMISSION, msg.sender);

        // check if market id is valid + check there is an active pool with maturityTimestamp requested
        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        int256 baseAmount = pool.executeDatedMakerOrder(
            params.accountId,
            params.marketId,
            params.maturityTimestamp,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta
        );

        Portfolio.loadOrCreate(params.accountId, params.marketId)
            .updatePosition(params.maturityTimestamp, 0, 0);
        market.updateOracleStateIfNeeded();

        annualizedNotionalAmount = 
            getSingleAnnualizedExposure(baseAmount, params.marketId, params.maturityTimestamp);

        emit MakerOrder(
            params.accountId,
            params.marketId,
            params.maturityTimestamp,
            msg.sender,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            block.timestamp
        );
    }

    function getSingleAnnualizedExposure(
        int256 executedBaseAmount,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal view returns (int256 annualizedNotionalAmount) {
        int256[] memory baseAmounts = new int256[](1);
        baseAmounts[0] = executedBaseAmount;
        annualizedNotionalAmount = ExposureHelpers.baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp)[0];
    }

}
