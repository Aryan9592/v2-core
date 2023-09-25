// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import {Tick} from "../ticks/Tick.sol";
import {TickMath} from "../ticks/TickMath.sol";
import {TickBitmap} from "../ticks/TickBitmap.sol";

import {FullMath} from "../math/FullMath.sol";
import {FixedPoint128} from "../math/FixedPoint128.sol";

import {Time} from "../time/Time.sol";

import { UD60x18, ZERO, UNIT } from "@prb/math/UD60x18.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import {ExposureHelpers} from "@voltz-protocol/products-dated-irs/src/libraries/ExposureHelpers.sol";
import {mulUDxInt} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

library VammHelpers {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);

    uint256 internal constant Q96 = 2**96;

    // ==================== EVENTS ======================
    /// @dev emitted after a successful swap transaction
    event Swap(
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        int256 desiredBaseAmount,
        uint160 sqrtPriceLimitX96,
        int256 quoteTokenDelta,
        int256 baseTokenDelta,
        uint256 blockTimestamp
    );

    /// @dev emitted after a successful mint or burn of liquidity on a given LP position
    event LiquidityChange(
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 liquidityDelta,
        uint256 blockTimestamp
    );

    event VAMMPriceChange(uint128 indexed marketId, uint32 indexed maturityTimestamp, int24 tick, uint256 blockTimestamp);

    // STRUCTS

    /// @dev the top level state of the swap, the results of which are recorded in storage at the end
    struct SwapState {
        /// @dev the amount remaining to be swapped in/out of the input/output asset
        int256 amountSpecifiedRemaining;
        /// @dev current sqrt(price)
        uint160 sqrtPriceX96;
        /// @dev the tick associated with the current price
        int24 tick;
        /// @dev the global quote token growth
        int256 trackerQuoteTokenGrowthGlobalX128;
        /// @dev the global variable token growth
        int256 trackerBaseTokenGrowthGlobalX128;
        int256 trackerAccruedInterestGrowthGlobalX128;
        /// @dev the current liquidity in range
        uint128 liquidity;
        /// @dev quoteTokenDelta that will be applied to the quote token balance of the position executing the swap
        int256 quoteTokenDeltaCumulative;
        /// @dev baseTokenDelta that will be applied to the variable token balance of the position executing the swap
        int256 baseTokenDeltaCumulative;
    }

    struct StepComputations {
        /// @dev the price at the beginning of the step
        uint160 sqrtPriceStartX96;
        /// @dev the next tick to swap to from the current tick in the swap direction
        int24 tickNext;
        /// @dev whether tickNext is initialized or not
        bool initialized;
        /// @dev sqrt(price) for the next tick (1/0)
        uint160 sqrtPriceNextX96;
        /// @dev how much is being swapped in in this step
        uint256 amountIn;
        /// @dev how much is being swapped out
        uint256 amountOut;
        UD60x18 averagePrice;
        /// @dev ...
        int256 quoteTokenDelta; // for LP
        /// @dev ...
        int256 baseTokenDelta; // for LP
    }

    /// @notice Computes the amount of notional coresponding to an amount of liquidity and price range
    /// @dev Calculates amount1 * (sqrt(upper) - sqrt(lower)).
    /// @param liquidity Liquidity per tick
    /// @param sqrtRatioAX96 A sqrt price representing the first tick boundary
    /// @param sqrtRatioBX96 A sqrt price representing the second tick boundary
    /// @return baseAmount The base amount of returned from liquidity
    function baseAmountFromLiquidity(int128 liquidity, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) 
        internal pure returns (int256 baseAmount) {
        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        uint256 absBase = FullMath
                .mulDiv(uint128(liquidity > 0 ? liquidity : -liquidity), sqrtRatioBX96 - sqrtRatioAX96, Q96);

        baseAmount = liquidity > 0 ? absBase.toInt() : -(absBase.toInt());
    }

    function unbalancedQuoteAmountFromBase(int256 baseAmount, uint160 sqrtRatioAX96, uint160 sqrtRatioBX96) 
        internal pure returns (int256 unbalancedQuoteAmount) {
        uint256 absQuote = FullMath
                .mulDiv(uint256(baseAmount > 0 ? baseAmount : -baseAmount), Q96, sqrtRatioBX96);
        absQuote = FullMath
                .mulDiv(absQuote, Q96, sqrtRatioAX96);

        unbalancedQuoteAmount = baseAmount > 0 ? -(absQuote.toInt()) : absQuote.toInt();
    }

    function calculateQuoteTokenDelta(
        int256 baseTokenDelta,
        UD60x18 averagePrice,
        UD60x18 spread,
        uint128 marketId
    ) 
        internal
        view
        returns (
            int256 quoteTokenDelta
        )
    {
        UD60x18 averagePriceWithSpread = averagePrice.add(spread);
        if (baseTokenDelta > 0) {
            averagePriceWithSpread = averagePrice.lt(spread) ? ZERO : averagePrice.sub(spread);
        }

        int256 exposure = ExposureHelpers.baseToExposure(
            baseTokenDelta,
            marketId
        );

        quoteTokenDelta = mulUDxInt(UNIT.add(averagePriceWithSpread), -exposure);
    }

    function calculateGlobalTrackerValues(
        VammHelpers.SwapState memory state,
        int256 balancedQuoteTokenDelta,
        int256 baseTokenDelta
    ) 
        internal
        pure
        returns (
            int256 stateQuoteTokenGrowthGlobalX128,
            int256 stateBaseTokenGrowthGlobalX128
        )
    {
        stateQuoteTokenGrowthGlobalX128 = 
            state.trackerQuoteTokenGrowthGlobalX128 + 
                FullMath.mulDivSigned(balancedQuoteTokenDelta, FixedPoint128.Q128, state.liquidity);

        stateBaseTokenGrowthGlobalX128 = 
            state.trackerBaseTokenGrowthGlobalX128 + 
                FullMath.mulDivSigned(baseTokenDelta, FixedPoint128.Q128, state.liquidity);
    }

    /// @dev Computes the agregate amount of base between two ticks, given a tick range and the amount of liquidity per tick.
    /// The answer must be a valid `int256`. Reverts on overflow.
    function baseBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityPerTick
    ) internal pure returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        return VammHelpers.baseAmountFromLiquidity(liquidityPerTick, sqrtRatioAX96, sqrtRatioBX96);
    }

    function unbalancedQuoteBetweenTicks(
        int24 tickLower,
        int24 tickUpper,
        int256 baseAmount
    ) internal pure returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        return VammHelpers.unbalancedQuoteAmountFromBase(baseAmount, sqrtRatioAX96, sqrtRatioBX96);
    }
}
