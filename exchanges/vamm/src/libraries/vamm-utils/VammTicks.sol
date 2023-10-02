//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { Tick } from "../ticks/Tick.sol";
import { TickMath } from "../ticks/TickMath.sol";

import { UD60x18, ZERO, ud, UNIT, convert } from "@prb/math/UD60x18.sol";

import {TickMath} from "../ticks/TickMath.sol";
import {DatedIrsVamm} from "../../storage/DatedIrsVamm.sol";
import {VammCustomErrors} from "./VammCustomErrors.sol";
import {FixedPoint96} from "../math/FixedPoint96.sol";
import {FullMath} from "../math/FullMath.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammTicks {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VammTicks for DatedIrsVamm.Data;

    /// @dev The default minimum tick of a vamm representing 1000%
    int24 internal constant DEFAULT_MIN_TICK = -69100;

    /// @dev The default minimum tick of a vamm repersenting 0.001%
    int24 internal constant DEFAULT_MAX_TICK = -DEFAULT_MIN_TICK;

    struct TickLimits {
        int24 minTick;
        int24 maxTick;
        uint160 minSqrtRatio;
        uint160 maxSqrtRatio;
    }

    function getPriceFromTick(int24 tick) internal pure returns (UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        return UD60x18.wrap(FullMath.mulDiv(1e18, FixedPoint96.Q96, sqrtPriceX96)).powu(2);
    }

    function getTickFromPrice(UD60x18 price) internal pure returns (int24 tick) {
        UD60x18 sqrtPrice = UNIT.div(price.mul(convert(100)).sqrt()); // 1 / sqrt(1.0001 ^ -tick)
        uint160 sqrtPriceX96 = uint160(sqrtPrice.mul(ud(FixedPoint96.Q96)).unwrap());
        return TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }

    // todo: further review during testing
    function getCurrentTickLimits(DatedIrsVamm.Data storage self, UD60x18 markPrice, UD60x18 markPriceBand) internal view returns (
        TickLimits memory currentTickLimits
    ) {
        (int24 dynamicMinTick, int24 dynamicMaxTick) = dynamicTickLimits(markPrice, markPriceBand);

        if (self.mutableConfig.minTickAllowed < dynamicMinTick) {
            currentTickLimits.minTick = dynamicMinTick;
            currentTickLimits.minSqrtRatio = TickMath.getSqrtRatioAtTick(dynamicMinTick);
        } else {
            currentTickLimits.minTick = self.mutableConfig.minTickAllowed;
            currentTickLimits.minSqrtRatio = self.minSqrtRatioAllowed;
        }

        if (dynamicMaxTick < self.mutableConfig.maxTickAllowed) {
            currentTickLimits.maxTick = dynamicMaxTick;
            currentTickLimits.maxSqrtRatio = TickMath.getSqrtRatioAtTick(dynamicMaxTick);
        } else {
            currentTickLimits.maxTick = self.mutableConfig.maxTickAllowed;
            currentTickLimits.maxSqrtRatio = self.maxSqrtRatioAllowed;
        }

        if (!(currentTickLimits.minTick <= self.vars.tick && self.vars.tick <= currentTickLimits.maxTick)) {
            revert VammCustomErrors.ExceededTickLimits(currentTickLimits.minTick, currentTickLimits.maxTick);
        }
    }

    /// @dev Common checks for valid tick inputs inside the min & max ticks
    function checkTicksInAllowedRange(DatedIrsVamm.Data storage self, int24 tickLower, int24 tickUpper) internal view {
        require(tickLower < tickUpper, "TLUR");
        require(tickLower >= self.mutableConfig.minTickAllowed, "TLMR");
        require(tickUpper <= self.mutableConfig.maxTickAllowed, "TUMR");
    }

    /// @dev Common checks for valid tick inputs inside the tick limits
    function checkTicksLimits(int24 tickLower, int24 tickUpper) internal pure {
        require(tickLower < tickUpper, "TLUL");
        require(tickLower >= DEFAULT_MIN_TICK, "TLML");
        require(tickUpper <= DEFAULT_MAX_TICK, "TUML");
    }

    function dynamicTickLimits(
        UD60x18 markPrice, UD60x18 markPriceBand
    ) internal pure returns (int24 dynamicMinTick, int24 dynamicMaxTick) {
        UD60x18 minPrice = (markPrice.gt(markPriceBand)) ? markPrice.sub(markPriceBand) : ZERO;
        UD60x18 maxPrice = markPrice.add(markPriceBand);

        dynamicMinTick = 
            getPriceFromTick(DEFAULT_MIN_TICK).gt(maxPrice) 
                ? getTickFromPrice(maxPrice) 
                : DEFAULT_MIN_TICK;
        
        dynamicMaxTick = 
            getPriceFromTick(DEFAULT_MAX_TICK).lt(minPrice)
                ? getTickFromPrice(minPrice)
                : DEFAULT_MAX_TICK;
    }

    function getSqrtRatioTargetX96(int256 amountSpecified, uint160 sqrtPriceNextX96, uint160 sqrtPriceLimitX96) 
        internal pure returns (uint160 sqrtRatioTargetX96) {
        // FT
        sqrtRatioTargetX96 = sqrtPriceNextX96 > sqrtPriceLimitX96
                ? sqrtPriceLimitX96
                : sqrtPriceNextX96;
        // VT 
        if(!(amountSpecified > 0)) {
            sqrtRatioTargetX96 = sqrtPriceNextX96 < sqrtPriceLimitX96
                ? sqrtPriceLimitX96
                : sqrtPriceNextX96;
        }
    }
}