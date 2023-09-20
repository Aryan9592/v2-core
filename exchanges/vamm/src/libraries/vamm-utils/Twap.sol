//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { Tick } from "../ticks/Tick.sol";

import { Oracle } from "../../storage/Oracle.sol";
import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { Time } from "../time/Time.sol";
import { VammTicks } from "./VammTicks.sol";
import { VammCustomErrors } from "./VammCustomErrors.sol";

import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18, UNIT, wrap, sqrt, ZERO, convert } from "@prb/math/UD60x18.sol";

library Twap {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Oracle for Oracle.Observation[65535];
    using SafeCastI256 for int256;

    /// @notice Calculates time-weighted geometric mean price based on the past `orderSizeWad` seconds
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    /// @param orderSizeWad The order size to use when adjusting the price for price impact or spread.
    /// Must not be zero if either of the boolean params is true because it used to indicate the direction 
    /// of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` 
    /// overflows when cast to a `U60x18`. Must have wad precision.
    /// @return geometricMeanPrice The geometric mean price, which might be adjusted according to input parameters. 
    /// May return zero if adjustments would take the price to or below zero 
    /// - e.g. when anticipated price impact is large because the order size is large.
    function twap(
        DatedIrsVamm.Data storage self, 
        uint32 secondsAgo, 
        int256 orderSizeWad
    )
        internal
        view
        returns (UD60x18 geometricMeanPrice)
    {
        /// Note that the logarithm of the weighted geometric mean is the arithmetic mean of the logarithms
        int24 arithmeticMeanTick = observe(self, secondsAgo);

        // Not yet adjusted
        geometricMeanPrice = VammTicks.getPriceFromTick(arithmeticMeanTick).div(convert(100));
        UD60x18 spreadImpactDelta = ZERO;
        UD60x18 priceImpactAsFraction = ZERO;

        if (orderSizeWad != 0) {
            spreadImpactDelta = self.mutableConfig.spread;
        }

        if (orderSizeWad != 0) {
            // note: the beta value is 1/2. if the value is set to something else and the 
            // `pow` function must be used, the order size must be limited to 192 bits
            priceImpactAsFraction = self.mutableConfig.priceImpactPhi.mul(
                sqrt(wrap((orderSizeWad > 0 ? orderSizeWad : -orderSizeWad).toUint()))
            );
        }

        // The projected price impact and spread of a trade will move the price up for buys, down for sells
        if (orderSizeWad > 0) {
            geometricMeanPrice = geometricMeanPrice.mul(UNIT.add(priceImpactAsFraction)).add(spreadImpactDelta);
        } else {
            if (spreadImpactDelta.gte(geometricMeanPrice)) {
                // The spread is higher than the price
                return ZERO;
            }
            if (priceImpactAsFraction.gte(UNIT)) {
                // The model suggests that the price will drop below zero after price impact
                return ZERO;
            }
            geometricMeanPrice = geometricMeanPrice.mul(UNIT.sub(priceImpactAsFraction)).sub(spreadImpactDelta);
        }
    }

    /// @notice Calculates time-weighted arithmetic mean tick
    /// @param secondsAgo Number of seconds in the past from which to calculate the time-weighted means
    function observe(DatedIrsVamm.Data storage self, uint32 secondsAgo)
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

            // Always round to negative infinity
            if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int56(uint56(secondsAgo)) != 0)) arithmeticMeanTick--;
        }
    }

    /// @notice Returns the cumulative tick as of each timestamp `secondsAgo` from the current block timestamp
    /// @dev To get a time weighted average tick or liquidity-in-range, you must call this with two values, one representing
    /// the beginning of the period and another for the end of the period. E.g., to get the last hour time-weighted average tick,
    /// you must call it with secondsAgos = [3600, 0].
    /// @dev The time weighted average tick represents the geometric time weighted average price of the pool, in
    /// log base sqrt(1.0001) of token1 / token0. The TickMath library can be used to go from a tick value to a ratio.
    /// @param secondsAgos From how long ago each cumulative tick value should be returned
    /// @return tickCumulatives Cumulative tick values as of each `secondsAgos` from the current block timestamp
    function observe(
        DatedIrsVamm.Data storage self,
        uint32[] memory secondsAgos)
        private
        view
        returns (int56[] memory tickCumulatives)
    {
        return
            self.vars.observations.observe(
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
    function increaseObservationCardinalityNext(DatedIrsVamm.Data storage self, uint16 observationCardinalityNext)
        internal
        lock(self)
    {
        uint16 observationCardinalityNextOld =  self.vars.observationCardinalityNext; // for the event

        uint16 observationCardinalityNextNew =  self.vars.observations.grow(
            observationCardinalityNextOld,
            observationCardinalityNext
        );

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