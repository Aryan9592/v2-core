/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/// @title Interface a Pool needs to adhere.
interface IPool is IERC165 {
    /// @notice returns a human-readable name for a given pool
    function name() external view returns (string memory);

    /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool
     * @dev It also enables account closures initiated by the Market Manager
     * @param marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * @param baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction depending on
     * @param sqrtPriceLimitX96 The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     */
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 sqrtPriceLimitX96,
        UD60x18 markPrice,
        UD60x18 markPriceBand
    )
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount);

    /**
     * @notice Provides liquidity to (or removes liquidty from) a given marketId & maturityTimestamp pair
     * @param accountId Id of the `Account` with which the lp wants to provide liqudity
     * @param marketId Id of the market in which the lp wants to provide liqudiity
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) within the tick range
     */
    function executeDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external returns (int256 baseAmount);

    /**
     * @notice Calculates base and quote token balances of all LP positions in the account.
     * @notice They represent the amount that has been locked in swaps
     * @param marketId Id of the market to look at 
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param accountId Id of the `Account` to look at
    */
    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool);

    /**
     * @notice Returns the base amount minted by an account but not used in a swap.
     * @param marketId Id of the market to look at 
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param accountId Id of the `Account` to look at
     * @return unfilledBaseLong Base amount left unused to the right of the current tick
     * @return unfilledBaseShort Base amount left unused to the left of the current tick
     * @return unfilledQuoteLong Simulated quote amount left unused to the right of the current tick
     * @return unfilledQuoteShort Simulated quote amount left unused to the left of the current tick
    */
    function getAccountUnfilledBaseAndQuote(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
    external
    view
    returns (
        uint256 unfilledBaseLong,
        uint256 unfilledBaseShort,
        uint256 unfilledQuoteLong,
        uint256 unfilledQuoteShort
    );

    /**
     * @notice Attempts to close all the unfilled and filled positions of a given account in the specified market
     * @param marketId Id of the market in which the positions should be closed
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param accountId Id of the `Account` with which the lp wants to provide liqudity
     * @return closedUnfilledBasePool Total amount of unfilled based that was burned
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        returns (int256 closedUnfilledBasePool);

    /**
     * @notice Get dated irs twap, adjusted for price impact and spread
     * @param marketId Id of the market for which we want to retrieve the dated irs twap
     * @param maturityTimestamp Timestamp at which a given market matures
     * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
     * @param orderSizeWad The order size to use when adjusting the price for price impact or spread.
     * Must not be zero if either of the boolean params is true because it used to indicate the direction 
     * of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` 
     * overflows when cast to a `U60x18`. Must have 18 decimals precision.
     * @return datedIRSTwap Geometric Time Weighted Average Fixed Rate
     */
    function getAdjustedDatedIRSTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 orderSizeWad,
        uint32 lookbackWindow
    )
        external
        view
        returns (UD60x18 datedIRSTwap);
}
