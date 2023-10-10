// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;


import { MTMObservation, PositionBalances } from "../DataTypes.sol";

import { LiquidityMath } from "../math/LiquidityMath.sol";
import { VammHelpers } from "../vamm-utils/VammHelpers.sol";

import { TraderPosition } from "@voltz-protocol/products-dated-irs/src/libraries/TraderPosition.sol";


/// @title Tick
/// @notice Contains functions for managing tick processes and relevant calculations
library Tick {
    int24 internal constant MAXIMUM_TICK_SPACING = 16384;

    // info stored for each initialized individual tick
    struct Info {
        /// @dev the total per-tick liquidity that references this tick (either as tick lower or tick upper)
        uint128 liquidityGross;

        /// @dev amount of per-tick liquidity added (subtracted) when tick is crossed from left to right (right to left),
        int128 liquidityNet;

        PositionBalances growthOutsideX128;

        /// @dev true iff the tick is initialized, i.e. the value is exactly equivalent to the expression liquidityGross != 0
        /// @dev these 8 bits are set to prevent fresh sstores when crossing newly initialized ticks
        bool initialized;
    }

    /// @notice Updates a tick and returns true if the tick was flipped from initialized to uninitialized, or vice versa
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The tick that will be updated
    /// @param tickCurrent The current tick
    /// @param liquidityDelta A new amount of liquidity to be added (subtracted) 
    ///     when tick is crossed from left to right (right to left)
    /// @param quoteTokenGrowthGlobalX128 The quote token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @param baseTokenGrowthGlobalX128 The variable token growth accumulated per unit of liquidity for the entire life of the vamm
    /// @param upper true for updating a position's upper tick, or false for updating a position's lower tick
    /// @param maxLiquidity The maximum liquidity allocation for a single tick
    /// @return flipped Whether the tick was flipped from initialized to uninitialized, or vice versa
    function update(
        mapping(int24 => Info) storage self,
        int24 tick,
        int24 tickCurrent,
        int128 liquidityDelta,
        int256 quoteTokenGrowthGlobalX128,
        int256 baseTokenGrowthGlobalX128,
        bool upper,
        uint128 maxLiquidity
    ) internal returns (bool flipped) {
        Info storage info = self[tick];

        uint128 liquidityGrossBefore = info.liquidityGross;
        require(
            int128(info.liquidityGross) + liquidityDelta >= 0,
            "not enough liquidity to burn"
        );
        uint128 liquidityGrossAfter = LiquidityMath.addDelta(
            liquidityGrossBefore,
            liquidityDelta
        );

        require(liquidityGrossAfter <= maxLiquidity, "LO");

        flipped = (liquidityGrossAfter == 0) != (liquidityGrossBefore == 0);

        if (liquidityGrossBefore == 0) {
            // by convention, we assume that all growth before a tick was initialized happened _below_ the tick
            if (tick <= tickCurrent) {
                info.growthOutsideX128.quote = quoteTokenGrowthGlobalX128;
                info.growthOutsideX128.base = baseTokenGrowthGlobalX128;
            }

            info.initialized = true;
        }

        /// check shouldn't we unintialize the tick if liquidityGrossAfter = 0?

        info.liquidityGross = liquidityGrossAfter;

        /// add comments
        // when the lower (upper) tick is crossed left to right (right to left), liquidity must be added (removed)
        info.liquidityNet = upper
            ? info.liquidityNet - liquidityDelta
            : info.liquidityNet + liquidityDelta;
    }

    /// @notice Clears tick data
    /// @param self The mapping containing all initialized tick information for initialized ticks
    /// @param tick The tick that will be cleared
    function clear(mapping(int24 => Tick.Info) storage self, int24 tick)
        internal
    {
        delete self[tick];
    }

    /// @notice Transitions to next tick as needed by price movement
    /// @param self The mapping containing all tick information for initialized ticks
    /// @param tick The destination tick of the transition
    /// @return liquidityNet The amount of liquidity added (subtracted) when tick is crossed from left to right (right to left)
    function cross(
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        PositionBalances memory growthGlobalX128,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal returns (int128 liquidityNet) {
        Tick.Info storage info = self[tick];

        MTMObservation memory newObservation = 
            VammHelpers.getNewMTMTimestampAndRateIndex(marketId, maturityTimestamp);

        TraderPosition.updateBalances(
            info.growthOutsideX128,
            0,
            0,
            newObservation
        );

        info.growthOutsideX128.quote = growthGlobalX128.quote - info.growthOutsideX128.quote;
        info.growthOutsideX128.base = growthGlobalX128.base - info.growthOutsideX128.base;
        info.growthOutsideX128.accruedInterest = growthGlobalX128.accruedInterest - info.growthOutsideX128.accruedInterest;

        liquidityNet = info.liquidityNet;
    }
}
