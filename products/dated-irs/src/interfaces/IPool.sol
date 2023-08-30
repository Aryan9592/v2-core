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
    function name(uint128 poolId) external view returns (string memory);

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

    function executeDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) external returns (int256 baseAmount);

    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool);

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
     * @param orderSize The order size to use when adjusting the price for price impact or spread. Must not be zero if either of the
     * Function will revert if `abs(orderSize)` overflows when cast to a `U60x18`
     * @return datedIRSTwap Geometric Time Weighted Average Fixed Rate
     */
    function getAdjustedDatedIRSTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 orderSize,
        uint32 lookbackWindow
    )
        external
        view
        returns (UD60x18 datedIRSTwap);
}
