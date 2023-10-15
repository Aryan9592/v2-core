// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { VammCustomErrors } from "./VammCustomErrors.sol";
import { VammTicks } from "./VammTicks.sol";

import { Tick } from "../ticks/Tick.sol";
import { TickMath } from "../ticks/TickMath.sol";

import { Oracle } from "./Oracle.sol";
import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { UNIT } from "@prb/math/UD60x18.sol";

/// @title VammConfiguration
/// @notice Contains methods to set the vamm configuration
library VammConfiguration {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Oracle for Oracle.Observation[65_535];
    using VammConfiguration for DatedIrsVamm.Data;
    using SetUtil for SetUtil.UintSet;

    /**
     * @notice Registers a new Dated IRS VAMM in storage along with the initial configuration
     * @param sqrtPriceX96 The sqrt ratio for which to compute the intital tick as a Q64.96
     * @param times List of observation timestamps for past prices
     * @param observedTicks List of observed ticks at the above timestamps
     * @param config Immutable configuration of the VAMM
     * @param mutableConfig Initial mutable configuration of the VAMM
     * @return irsVamm The VAMM state
     */
    function create(
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks,
        DatedIrsVamm.Immutable memory config,
        DatedIrsVamm.Mutable memory mutableConfig
    )
        internal
        returns (DatedIrsVamm.Data storage irsVamm)
    {
        uint256 id = uint256(keccak256(abi.encodePacked(config.marketId, config.maturityTimestamp)));
        irsVamm = DatedIrsVamm.load(id);

        if (irsVamm.immutableConfig.maturityTimestamp != 0) {
            revert VammCustomErrors.MarketAndMaturityCombinaitonAlreadyExists(config.marketId, config.maturityTimestamp);
        }

        if (config.maturityTimestamp <= block.timestamp) {
            revert VammCustomErrors.MaturityMustBeInFuture(block.timestamp, config.maturityTimestamp);
        }

        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(config.tickSpacing > 0 && config.tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

        irsVamm.immutableConfig = config;

        initialize(irsVamm, sqrtPriceX96, times, observedTicks);

        configure(irsVamm, mutableConfig);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(
        DatedIrsVamm.Data storage self,
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks
    )
        private
    {
        if (sqrtPriceX96 == 0) {
            revert VammCustomErrors.ExpectedNonZeroSqrtPriceForInit(sqrtPriceX96);
        }
        if (self.vars.sqrtPriceX96 != 0) {
            revert VammCustomErrors.ExpectedSqrtPriceZeroBeforeInit(self.vars.sqrtPriceX96);
        }

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (self.vars.observationCardinality, self.vars.observationCardinalityNext) =
            self.vars.observations.initialize(times, observedTicks);
        self.vars.observationIndex = self.vars.observationCardinality - 1;
        self.vars.unlocked = true;
        self.vars.tick = tick;
        self.vars.sqrtPriceX96 = sqrtPriceX96;
    }

    /**
     * @notice Configures an existing Dated IRS VAMM
     * @param self The VAMM state
     * @param config New mutable configuration to be set
     */
    function configure(DatedIrsVamm.Data storage self, DatedIrsVamm.Mutable memory config) internal {
        self.mutableConfig = config;
        propagateMinAndMaxTicks(self, config.minTickAllowed, config.maxTickAllowed);
    }

    function propagateMinAndMaxTicks(
        DatedIrsVamm.Data storage self,
        int24 minTickAllowed,
        int24 maxTickAllowed
    )
        private
    {
        if (
            minTickAllowed < VammTicks.DEFAULT_MIN_TICK || maxTickAllowed > VammTicks.DEFAULT_MAX_TICK
                || self.vars.tick < minTickAllowed || self.vars.tick > maxTickAllowed
        ) {
            revert VammCustomErrors.ExceededTickLimits(minTickAllowed, maxTickAllowed);
        }

        self.minSqrtRatioAllowed = TickMath.getSqrtRatioAtTick(minTickAllowed);
        self.maxSqrtRatioAllowed = TickMath.getSqrtRatioAtTick(maxTickAllowed);
    }
}
