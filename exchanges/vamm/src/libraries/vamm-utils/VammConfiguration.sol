//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../ticks/Tick.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { VammCustomErrors } from "../../libraries/errors/VammCustomErrors.sol";

import "../../storage/Oracle.sol";
import "../../storage/DatedIrsVamm.sol";
import "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracleModule.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammConfiguration {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Oracle for Oracle.Observation[65535];
    using VammConfiguration for DatedIrsVamm.Data;

    struct Mutable {
        /// @dev the phi value to use when adjusting a TWAP price for the likely price impact of liquidation
        UD60x18 priceImpactPhi;
        /// @dev the spread taken by LPs on each trade. 
        ///     As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
        /// @dev minimum seconds between observation entries in the oracle buffer
        uint32 minSecondsBetweenOracleObservations;
        /// @dev The minimum allowed tick of the vamm
        int24 minTickAllowed;
        /// @dev The maximum allowed tick of the vamm
        int24 maxTickAllowed;
    }

    struct Immutable {
        /// @dev UNIX timestamp in seconds marking swap maturity
        uint32 maturityTimestamp;
        /// @dev Maximun liquidity amount per tick
        uint128 _maxLiquidityPerTick;
        /// @dev Granularity of ticks
        int24 _tickSpacing;
        /// @dev market id used to identify vamm alongside maturity timestamp
        uint128 marketId;
    }

    /// @dev frequently-updated state of the VAMM
    struct State {
        /**
         * @dev do not rearrange storage from sqrtPriceX96 to unlocked including.
         * It is arranged on purpose to for one single storage slot.
         */

        // the current price of the pool as a sqrt(trackerBaseToken/trackerQuoteToken) Q64.96 value
        uint160 sqrtPriceX96;
        // the current tick of the vamm, i.e. according to the last tick transition that was run.
        int24 tick;
        // the most-recently updated index of the observations array
        uint16 observationIndex;
        // the current maximum number of observations that are being stored
        uint16 observationCardinality;
        // the next maximum number of observations to store, triggered in observations.write
        uint16 observationCardinalityNext;
        // whether the pool is locked
        bool unlocked;

        /// Circular buffer of Oracle Observations. Resizable but no more than type(uint16).max slots in the buffer
        Oracle.Observation[65535] observations;
        /// @dev Maps from an account address to a list of the position IDs of positions associated with that account address. 
        ///     Use the `positions` mapping to see full details of any given `LPPosition`.
        mapping(uint128 => uint128[]) positionsInAccount;
        /// @notice The currently in range liquidity available to the pool
        /// @dev This value has no relationship to the total liquidity across all ticks
        uint128 liquidity;
        /// @dev total amount of variable tokens in vamm
        int256 trackerQuoteTokenGrowthGlobalX128;
        /// @dev total amount of base tokens in vamm
        int256 trackerBaseTokenGrowthGlobalX128;
        /// @dev map from tick to tick info
        mapping(int24 => Tick.Info) _ticks;
        /// @dev map from tick to tick bitmap
        mapping(int16 => uint256) _tickBitmap;
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function create(
        uint128 _marketId,
        uint160 _sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks,
        Immutable memory _config,
        Mutable memory _mutableConfig
    ) internal returns (DatedIrsVamm.Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(_marketId, _config.maturityTimestamp)));
        irsVamm = DatedIrsVamm.exists(id);

        if (irsVamm.immutableConfig.maturityTimestamp != 0) {
            revert VammCustomErrors.MarketAndMaturityCombinaitonAlreadyExists(_marketId, _config.maturityTimestamp);
        }

        if (_config.maturityTimestamp <= block.timestamp) {
            revert VammCustomErrors.MaturityMustBeInFuture(block.timestamp, _config.maturityTimestamp);
        }

        // tick spacing is capped at 16384 to prevent the situation where tickSpacing is so large that
        // TickBitmap#nextInitializedTickWithinOneWord overflows int24 container from a valid tick
        // 16384 ticks represents a >5x price change with ticks of 1 bips
        require(_config._tickSpacing > 0 && _config._tickSpacing < Tick.MAXIMUM_TICK_SPACING, "TSOOB");

        irsVamm.immutableConfig.maturityTimestamp = _config.maturityTimestamp;
        irsVamm.immutableConfig._maxLiquidityPerTick = _config._maxLiquidityPerTick;
        irsVamm.immutableConfig._tickSpacing = _config._tickSpacing;
        irsVamm.immutableConfig.marketId = _marketId;

        initialize(irsVamm, _sqrtPriceX96, times, observedTicks);

        configure(irsVamm, _mutableConfig);
    }

    /// @dev not locked because it initializes unlocked
    function initialize(
        DatedIrsVamm.Data storage self,
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks
    ) internal {
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

    function configure(
        DatedIrsVamm.Data storage self,
        VammConfiguration.Mutable memory _config) internal {

        if (_config.priceImpactPhi.gt(UNIT)) {
            revert VammCustomErrors.PriceImpactOutOfBounds();
        }

        self.mutableConfig.priceImpactPhi = _config.priceImpactPhi;
        self.mutableConfig.spread = _config.spread;

        self.setMinAndMaxTicks(_config.minTickAllowed, _config.maxTickAllowed);
    }

    function setMinAndMaxTicks(
        DatedIrsVamm.Data storage self,
        int24 _minTickAllowed,
        int24 _maxTickAllowed
    ) internal {
        // todo: might be able to remove self.vars.tick < _minTickAllowed || self.vars.tick > _maxTickAllowed
        // need to make sure the currently-held invariant that "current tick is always within the allowed tick range"
        // does not have unwanted consequences
        if(
            _minTickAllowed < TickMath.MIN_TICK_LIMIT || _maxTickAllowed > TickMath.MAX_TICK_LIMIT ||
            self.vars.tick < _minTickAllowed || self.vars.tick > _maxTickAllowed
        ) {
            revert VammCustomErrors.ExceededTickLimits(_minTickAllowed, _maxTickAllowed);
        }

        // todo: can this be removed in the future for better flexibility?
        if(_minTickAllowed + _maxTickAllowed != 0) {
            revert VammCustomErrors.AsymmetricTicks(_minTickAllowed, _maxTickAllowed);
        }

        self.mutableConfig.minTickAllowed = _minTickAllowed;
        self.mutableConfig.maxTickAllowed = _maxTickAllowed;
        self.minSqrtRatioAllowed = TickMath.getSqrtRatioAtTick(_minTickAllowed);
        self.maxSqrtRatioAllowed = TickMath.getSqrtRatioAtTick(_maxTickAllowed);
    }
}
