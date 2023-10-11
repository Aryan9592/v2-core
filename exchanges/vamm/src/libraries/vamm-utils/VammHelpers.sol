// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;


import { PositionBalances } from "../DataTypes.sol";

import { Tick } from "../ticks/Tick.sol";
import { TickMath } from "../ticks/TickMath.sol";
import { TickBitmap } from "../ticks/TickBitmap.sol";
import { FullMath } from "../math/FullMath.sol";
import { FixedPoint128 } from "../math/FixedPoint128.sol";

import { UD60x18, ZERO } from "@prb/math/UD60x18.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";


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
        PositionBalances tokenDeltas,
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

        PositionBalances growthGlobalX128;

        PositionBalances tokenDeltaCumulative;

        /// @dev the current liquidity in range
        uint128 liquidity;
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
        PositionBalances tokenDeltas;
    }

    function amountsFromLiquidity(
        uint128 liquidity, 
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (uint256 absBase, uint256 absUnbalancedQuote) {

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);

        absBase = FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, Q96);

        absUnbalancedQuote = 
            FullMath.mulDiv(
                FullMath.mulDiv(absBase, Q96, sqrtRatioBX96),
                Q96,
                sqrtRatioAX96
            );
    }

    function liquidityFromBase(
        int256 base, 
        int24 tickLower,
        int24 tickUpper
    ) internal pure returns (int128 liquidity) {

        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

        if (sqrtRatioAX96 > sqrtRatioBX96)
            (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
        
        uint256 absLiquidity = FullMath
            .mulDiv(uint256(base > 0 ? base : -base), Q96, sqrtRatioBX96 - sqrtRatioAX96);

        return base > 0 ? absLiquidity.toInt().to128() : -(absLiquidity.toInt().to128());
    }

    function calculateQuoteTokenDelta(
        int256 baseTokenDelta,
        UD60x18 averagePrice,
        UD60x18 spread,
        UD60x18 exposureFactor
    ) 
        internal
        pure
        returns (
            int256 quoteTokenDelta
        )
    {
        UD60x18 averagePriceWithSpread = averagePrice.add(spread);
        if (baseTokenDelta > 0) {
            averagePriceWithSpread = averagePrice.lt(spread) ? ZERO : averagePrice.sub(spread);
        }

        int256 exposure = mulUDxInt(exposureFactor, baseTokenDelta);

        quoteTokenDelta = mulUDxInt(averagePriceWithSpread, -exposure);
    }

    function calculateGlobalTrackerValues(
        VammHelpers.SwapState memory state,
        PositionBalances memory deltas
    ) internal pure returns (PositionBalances memory) {
        return PositionBalances({
            base: state.growthGlobalX128.base + 
                FullMath.mulDivSigned(deltas.base, FixedPoint128.Q128, state.liquidity),

            quote: state.growthGlobalX128.quote + 
                FullMath.mulDivSigned(deltas.quote, FixedPoint128.Q128, state.liquidity),

            extraCashflow: state.growthGlobalX128.extraCashflow + 
                FullMath.mulDivSigned(deltas.extraCashflow, FixedPoint128.Q128, state.liquidity)
        });
    }
}
