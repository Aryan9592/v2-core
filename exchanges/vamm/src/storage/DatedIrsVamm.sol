// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { Oracle } from "../libraries/vamm-utils/Oracle.sol";
import { PoolConfiguration } from "./PoolConfiguration.sol";

import { Tick } from "../libraries/ticks/Tick.sol";

import { AccountBalances } from "../libraries/vamm-utils/AccountBalances.sol";
import { Swap } from "../libraries/vamm-utils/Swap.sol";
import { LP } from "../libraries/vamm-utils/LP.sol";
import { VammConfiguration } from "../libraries/vamm-utils/VammConfiguration.sol";
import { VammCustomErrors } from "../libraries/vamm-utils/VammCustomErrors.sol";

import { UnfilledBalances, PositionBalances, RateOracleObservation } from "../libraries/DataTypes.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { IMarketConfigurationModule } from
    "@voltz-protocol/products-dated-irs/src/interfaces/IMarketConfigurationModule.sol";
import { IRateOracleModule } from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracleModule.sol";

/**
 * @title Defines the storage and main capabilities of a dated IRS VAMM
 */
library DatedIrsVamm {
    /**
     * @dev Mutable configuration of the VAMM
     */
    struct Mutable {
        /// @dev the spread taken by LPs on each trade.
        ///     As decimal number where 1 = 100%. E.g. 0.003 means that the spread is 0.3% of notional
        UD60x18 spread;
        /// @dev minimum seconds between observation entries in the oracle buffer
        uint32 minSecondsBetweenOracleObservations;
        /// @dev The minimum allowed tick of the vamm
        int24 minTickAllowed;
        /// @dev The maximum allowed tick of the vamm
        int24 maxTickAllowed;
        /// @dev The window that blocks orders before maturity to avoid manipulations
        uint32 inactiveWindowBeforeMaturity;
    }

    /**
     * @dev Immutable configuration of the VAMM
     */
    struct Immutable {
        /// @dev UNIX timestamp in seconds marking swap maturity
        uint32 maturityTimestamp;
        /// @dev Maximun liquidity amount per tick
        uint128 maxLiquidityPerTick;
        /// @dev Granularity of ticks
        int24 tickSpacing;
        /// @dev market id used to identify vamm alongside maturity timestamp
        uint128 marketId;
    }

    /**
     * @dev frequently-updated state of the VAMM
     */
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
        Oracle.Observation[65_535] observations;
        /// @dev Maps from an account address to a list of the position IDs of positions associated with that account
        /// address.
        ///      Use the `positions` mapping to see full details of any given `LPPosition`.
        mapping(uint128 => SetUtil.UintSet) accountPositions;
        /// @notice The currently in range liquidity available to the pool
        /// @dev This value has no relationship to the total liquidity across all ticks
        uint128 liquidity;
        PositionBalances growthGlobalX128;
        /// @dev map from tick to tick info
        mapping(int24 => Tick.Info) ticks;
        /// @dev map from tick to tick bitmap
        mapping(int16 => uint256) tickBitmap;
    }

    /**
     * @dev Internal, frequently-updated state of the VAMM, which is compressed into one storage slot.
     */
    struct Data {
        /// @dev vamm config set at initialization, can't be modified after creation
        Immutable immutableConfig;
        /// @dev configurable vamm config
        Mutable mutableConfig;
        /// @dev vamm state frequently-updated
        State vars;
        /// @dev Equivalent to getSqrtRatioAtTick(minTickAllowed)
        uint160 minSqrtRatioAllowed;
        /// @dev Equivalent to getSqrtRatioAtTick(maxTickAllowed)
        uint160 maxSqrtRatioAllowed;
    }

    /**
     * @dev Parameters required by the swap frunction
     */
    struct SwapParams {
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap
        ///      as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
        /// @dev Mark price used to compute dynamic price limits
        UD60x18 markPrice;
        /// @dev Fixed Mark Price Band applied to the mark price to compute the dynamic price limits
        UD60x18 markPriceBand;
    }

    /**
     * @dev Calls the VammConfiguration.create() function with the given parameters
     */
    function create(
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks,
        Immutable memory config,
        Mutable memory mutableConfig
    )
        internal
        returns (Data storage)
    {
        return VammConfiguration.create(sqrtPriceX96, times, observedTicks, config, mutableConfig);
    }

    /**
     * @dev Calls the VammConfiguration.configure() function with the given parameters
     */
    function configure(DatedIrsVamm.Data storage self, DatedIrsVamm.Mutable memory config) internal {
        VammConfiguration.configure(self, config);
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        if (id == 0) {
            revert VammCustomErrors.IRSVammNotFound(0);
        }
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function exists(uint256 id) internal view returns (Data storage irsVamm) {
        irsVamm = load(id);
        if (irsVamm.immutableConfig.maturityTimestamp == 0) {
            revert VammCustomErrors.IRSVammNotFound(id);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (Data storage irsVamm)
    {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = exists(id);
    }

    /**
     * @dev Calls the Swap.vammSwap() function with the given parameters
     */
    function vammSwap(
        DatedIrsVamm.Data storage self,
        DatedIrsVamm.SwapParams memory params
    )
        internal
        returns (PositionBalances memory /* tokenDeltas */ )
    {
        return Swap.vammSwap(self, params);
    }

    /**
     * @dev Calls the LP.executeDatedMakerOrder() function with the given parameters
     */
    function executeDatedMakerOrder(
        DatedIrsVamm.Data storage self,
        uint128 accountId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        internal
    {
        LP.executeDatedMakerOrder(self, accountId, tickLower, tickUpper, liquidityDelta);
    }

    /**
     * @dev Calls the AccountBalances.getAccountUnfilledBalances() function with the given parameters
     */
    function getAccountUnfilledBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (UnfilledBalances memory)
    {
        return AccountBalances.getAccountUnfilledBalances(self, accountId);
    }

    /**
     * @dev Calls the AccountBalances.getAccountPositionBalances() function with the given parameters
     */
    function getAccountPositionBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (PositionBalances memory)
    {
        return AccountBalances.getAccountPositionBalances(self, accountId);
    }

    /**
     * @dev Calls the RateOracleModule.getLatestRateIndex() function with the given parameters
     */
    function getLatestRateIndex(DatedIrsVamm.Data storage self) internal view returns (RateOracleObservation memory) {
        IRateOracleModule rateOracleModule = IRateOracleModule(PoolConfiguration.load().marketManagerAddress);

        return
            rateOracleModule.getLatestRateIndex(self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp);
    }

    /**
     * @dev Calls the IMarketConfigurationModule.getExposureFactor() function with the given parameters
     */
    function getExposureFactor(DatedIrsVamm.Data storage self) internal view returns (UD60x18) {
        IMarketConfigurationModule marketConfigurationModule =
            IMarketConfigurationModule(PoolConfiguration.load().marketManagerAddress);

        return marketConfigurationModule.getExposureFactor(self.immutableConfig.marketId);
    }
}
