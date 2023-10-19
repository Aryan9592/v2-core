/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { Portfolio } from "../../storage/Portfolio.sol";
import { Market } from "../../storage/Market.sol";

/**
 * @title Library for settlement logic.
 */
library Settlement {
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @notice Emitted when a position is settled.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param collateralType The address of the collateral.
     * @param blockTimestamp The current block timestamp.
     */
    event DatedIRSPositionSettled(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        address collateralType,
        int256 settlementCashflowInQuote,
        uint256 blockTimestamp
    );

    /**
     * @notice Returns the address that owns a given account, as recorded by the protocol.
     * @param accountId Id of the account that wants to settle
     * @param marketId Id of the market in which the account wants to settle (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to settle
     */
    function settle(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        returns (int256 settlementCashflowInQuote)
    {
        Market.Data storage market = Market.exists(marketId);
        market.updateRateIndexAtMaturityCache(maturityTimestamp);

        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        settlementCashflowInQuote = portfolio.settle(maturityTimestamp, market.marketConfig.poolAddress);

        emit DatedIRSPositionSettled(
            accountId, marketId, maturityTimestamp, market.quoteToken, settlementCashflowInQuote, block.timestamp
        );
    }
}
