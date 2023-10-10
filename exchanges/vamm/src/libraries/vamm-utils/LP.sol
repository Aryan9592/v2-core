//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { LPPosition } from "../../storage/LPPosition.sol";
import { PoolConfiguration } from "../../storage/PoolConfiguration.sol";

import { Time } from "../time/Time.sol";

import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";
import { Tick } from "../ticks/Tick.sol";
import { TickBitmap } from "../ticks/TickBitmap.sol";
import { LiquidityMath } from "../math/LiquidityMath.sol";
import {AccountBalances} from "./AccountBalances.sol";

import { VammCustomErrors } from "./VammCustomErrors.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

library LP {
    using LPPosition for LPPosition.Data;
    using SetUtil for SetUtil.UintSet;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using DatedIrsVamm for DatedIrsVamm.Data;

    /**
     * @notice Executes a dated maker order that provides liquidity to (or removes liquidty from) this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function executeDatedMakerOrder(
        DatedIrsVamm.Data storage self,
        uint128 accountId,
        uint128 marketId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
    internal
    { 
        uint32 maturityTimestamp = self.immutableConfig.maturityTimestamp;
        Time.checkCurrentTimestampMaturityTimestampDelta(maturityTimestamp);

        LPPosition.Data storage position = 
            LPPosition.loadOrCreate(accountId, marketId, maturityTimestamp, tickLower, tickUpper);

        // Track position and check account positions limit
        {
            uint256 positionsLimit = PoolConfiguration.load().makerPositionsPerAccountLimit;
            SetUtil.UintSet storage accountPositions = self.vars.accountPositions[accountId];

            if (!accountPositions.contains(position.id)) {
                accountPositions.add(position.id);

                if (accountPositions.length() > positionsLimit) {
                    revert VammCustomErrors.TooManyLpPositions(accountId);
                }
            }
        }

        // this also checks if the position has enough liquidity to burn
        position.updateTokenBalances(
            marketId,
            maturityTimestamp,
            AccountBalances.computeGrowthInside(self, tickLower, tickUpper)
        );

        position.updateLiquidity(liquidityDelta);

        updateLiquidity(self, tickLower, tickUpper, liquidityDelta);

        emit VammHelpers.LiquidityChange(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            msg.sender,
            accountId,
            tickLower,
            tickUpper,
            liquidityDelta,
            block.timestamp
        );
    }

    /// Mints (`liquidityDelta > 0`) or burns (`liquidityDelta < 0`) 
    /// `liquidityDelta` liquidity for the specified `accountId`, uniformly between the specified ticks.
    function updateLiquidity(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) private
      lock(self)
    {
        Time.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        if (liquidityDelta > 0) {
            VammTicks.checkTicksInAllowedRange(self, tickLower, tickUpper);
        } else {
            VammTicks.checkTicksLimits(tickLower, tickUpper);
        }
        
        bool flippedLower;
        bool flippedUpper;

        /// @dev update the ticks if necessary
        if (liquidityDelta != 0) {
            (flippedLower, flippedUpper) = flipTicks(
                self,
                tickLower,
                tickUpper,
                liquidityDelta
            );
        }

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                self.vars.ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self.vars.ticks.clear(tickUpper);
            }
        }

        if (liquidityDelta != 0) {
            if (tickLower <= self.vars.tick && self.vars.tick < tickUpper) {
                // current tick is inside the passed range
                uint128 liquidityBefore = self.vars.liquidity; // SLOAD for gas optimization

                self.vars.liquidity = LiquidityMath.addDelta(
                    liquidityBefore,
                    liquidityDelta
                );
            }
        }
    }

    function flipTicks(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        private
        returns (
            bool flippedLower,
            bool flippedUpper
        )
    {
        int24 tickSpacing = self.immutableConfig.tickSpacing;
        uint128 maxLiquidityPerTick = self.immutableConfig.maxLiquidityPerTick;

        /// @dev isUpper = false
        flippedLower = self.vars.ticks.update(
            tickLower,
            self.vars.tick,
            liquidityDelta,
            self.vars.growthGlobalX128.quote,
            self.vars.growthGlobalX128.base,
            false,
            maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = self.vars.ticks.update(
            tickUpper,
            self.vars.tick,
            liquidityDelta,
            self.vars.growthGlobalX128.quote,
            self.vars.growthGlobalX128.base,
            true,
            maxLiquidityPerTick
        );

        if (flippedLower) {
            self.vars.tickBitmap.flipTick(tickLower, tickSpacing);
        }

        if (flippedUpper) {
            self.vars.tickBitmap.flipTick(tickUpper, tickSpacing);
        }
    }

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock(DatedIrsVamm.Data storage self) {
        if (!self.vars.unlocked) {
            revert VammCustomErrors.Lock(true);
        }
        self.vars.unlocked = false;
        _;
        if (self.vars.unlocked) {
            revert VammCustomErrors.Lock(false);
        }
        self.vars.unlocked = true;
    }
}