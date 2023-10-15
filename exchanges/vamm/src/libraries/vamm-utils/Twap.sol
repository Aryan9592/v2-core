// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { VammTicks } from "./VammTicks.sol";
import { VammCustomErrors } from "./VammCustomErrors.sol";

import { Tick } from "../ticks/Tick.sol";

import { Oracle } from "./Oracle.sol";
import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";

import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { IPool } from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

import { UD60x18, UNIT as UNIT_ud, ZERO as ZERO_ud, convert as convert_ud } from "@prb/math/UD60x18.sol";

/// @title Twap library
/// @notice Libary that supports the calculation the time-weighted average price
library Twap {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Oracle for Oracle.Observation[65_535];
    using SafeCastI256 for int256;

    /// @notice Calculates time-weighted geometric mean price based on the past `secondsAgo` seconds
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @param orderDirection Whether the order is long, short, or zero (used when adjusting for price impact or
    /// spread).
    /// @return geometricMeanPrice The geometric mean price, which might be adjusted according to input parameters.
    /// May return zero if adjustments would take the price to or below zero
    /// - e.g. when anticipated price impact is large because the order size is large.
    function twap(
        DatedIrsVamm.Data storage self,
        uint32 secondsAgo,
        IPool.OrderDirection orderDirection,
        UD60x18 pSlippage
    )
        internal
        view
        returns (UD60x18 geometricMeanPrice)
    {
        /// Note that the logarithm of the weighted geometric mean is the arithmetic mean of the logarithms
        int24 arithmeticMeanTick = observe(self, secondsAgo);

        // Not yet adjusted
        geometricMeanPrice = VammTicks.getPriceFromTick(arithmeticMeanTick).div(convert_ud(100));

        // Apply slippage
        geometricMeanPrice = applySlippage(geometricMeanPrice, orderDirection, pSlippage);

        // Apply spread
        geometricMeanPrice = applySpread(geometricMeanPrice, orderDirection, self.mutableConfig.spread);
    }

    function applySlippage(
        UD60x18 price,
        IPool.OrderDirection orderDirection,
        UD60x18 pSlippage
    )
        private
        pure
        returns (UD60x18 /* slippedPrice */ )
    {
        if (orderDirection == IPool.OrderDirection.Zero) {
            return price;
        }

        if (orderDirection == IPool.OrderDirection.Long) {
            return price.add(pSlippage);
        }

        if (pSlippage.gte(price)) {
            // The model suggests that the price will drop below zero after price impact
            return ZERO_ud;
        }

        return price.sub(pSlippage);
    }

    function applySpread(
        UD60x18 price,
        IPool.OrderDirection orderDirection,
        UD60x18 spread
    )
        private
        pure
        returns (UD60x18 /* spreadPrice */ )
    {
        if (orderDirection == IPool.OrderDirection.Zero) {
            return price;
        }

        if (orderDirection == IPool.OrderDirection.Long) {
            return price.add(spread);
        }

        if (price.lte(spread)) {
            return ZERO_ud;
        }

        return price.sub(spread);
    }

    /// @notice Calculates time-weighted arithmetic mean tick
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    function observe(
        DatedIrsVamm.Data storage self,
        uint32 secondsAgo
    )
        private
        view
        returns (int24 arithmeticMeanTick)
    {
        if (secondsAgo == 0) {
            // return the current tick if secondsAgo == 0
            arithmeticMeanTick = self.vars.tick;
        } else {
            uint32[] memory secondsAgos = new uint32[](2);
            secondsAgos[0] = secondsAgo;
            secondsAgos[1] = 0;

            int56[] memory tickCumulatives = observe(self, secondsAgos);

            int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];
            arithmeticMeanTick = int24(tickCumulativesDelta / int56(uint56(secondsAgo)));
        }
    }

    /// @notice Returns the cumulative tick as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one
    /// representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted
    /// average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of token1 / token0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    function observe(
        DatedIrsVamm.Data storage self,
        uint32[] memory secondsAgos
    )
        private
        view
        returns (int56[] memory tickCumulatives)
    {
        return self.vars.observations.observe(
            Time.blockTimestampTruncated(),
            secondsAgos,
            self.vars.tick,
            self.vars.observationIndex,
            self.vars.observationCardinality
        );
    }

    /// @notice Increase the maximum number of price and liquidity observations that this pool will store
    /// @dev This method is no-op if the pool already has an observationCardinalityNext greater than or equal to
    /// the input observationCardinalityNext.
    /// @param observationCardinalityNext The desired minimum number of observations for the pool to store
    function increaseObservationCardinalityNext(
        DatedIrsVamm.Data storage self,
        uint16 observationCardinalityNext
    )
        internal
        lock(self)
    {
        uint16 observationCardinalityNextOld = self.vars.observationCardinalityNext; // for the event

        uint16 observationCardinalityNextNew =
            self.vars.observations.grow(observationCardinalityNextOld, observationCardinalityNext);

        self.vars.observationCardinalityNext = observationCardinalityNextNew;
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
