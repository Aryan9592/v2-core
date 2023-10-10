// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;


import { MTMObservation, PositionBalances } from "../DataTypes.sol";

import { Tick } from "../ticks/Tick.sol";
import { TickMath } from "../ticks/TickMath.sol";
import { TickBitmap } from "../ticks/TickBitmap.sol";
import { FullMath } from "../math/FullMath.sol";
import { FixedPoint128 } from "../math/FixedPoint128.sol";

import { PoolConfiguration } from "../../storage/PoolConfiguration.sol";

import { UD60x18, ZERO, UNIT, unwrap } from "@prb/math/UD60x18.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { IRateOracleModule } from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracleModule.sol";
import { IMarketConfigurationModule } from "@voltz-protocol/products-dated-irs/src/interfaces/IMarketConfigurationModule.sol";
import { Market } from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";


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

        int256 exposure = baseToExposure(
            baseTokenDelta,
            marketId
        );

        quoteTokenDelta = mulUDxInt(averagePriceWithSpread, -exposure);
    }

    function baseToExposure(
        int256 baseAmount,
        uint128 marketId
    )
        private
        view
        returns (int256 exposure)
    {
        UD60x18 factor = exposureFactor(marketId);
        exposure = mulUDxInt(factor, baseAmount);
    }

    function exposureFactor(uint128 marketId) private view returns (UD60x18 factor) {
        address marketManagerAddress = PoolConfiguration.load().marketManagerAddress;
        bytes32 marketType = IMarketConfigurationModule(marketManagerAddress)
            .getMarketType(marketId);
        if (marketType == Market.LINEAR_MARKET) {
            return UNIT;
        } else if (marketType == Market.COMPOUNDING_MARKET) {
            UD60x18 currentLiquidityIndex = IRateOracleModule(marketManagerAddress)
                .getRateIndexCurrent(marketId);
            return currentLiquidityIndex;
        }

        revert Market.UnsupportedMarketType(marketType);
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

    function getNewMTMTimestampAndRateIndex(
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal view returns (MTMObservation memory observation) {
        IRateOracleModule marketManager = 
            IRateOracleModule(PoolConfiguration.load().marketManagerAddress);

        if (block.timestamp < maturityTimestamp) {
            observation.timestamp = block.timestamp;
            observation.rateIndex = marketManager.getRateIndexCurrent(marketId);
        } else {
            observation.timestamp = maturityTimestamp;
            observation.rateIndex = marketManager.getRateIndexMaturity(marketId, maturityTimestamp);
        }
    }

    
}
