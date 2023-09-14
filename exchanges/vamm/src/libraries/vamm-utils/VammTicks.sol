//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../ticks/Tick.sol";

import { UD60x18, ZERO, ud } from "@prb/math/UD60x18.sol";

import {TickMath} from "../ticks/TickMath.sol";

import {DatedIrsVamm} from "../../storage/DatedIrsVamm.sol";
import {VammCustomErrors} from "../errors/VammCustomErrors.sol";
import {FixedPoint96} from "../math/FixedPoint96.sol";
import {FullMath} from "../math/FullMath.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammTicks {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VammTicks for DatedIrsVamm.Data;

    struct TickLimits {
        int24 minTick;
        int24 maxTick;
        uint160 minSqrtRatio;
        uint160 maxSqrtRatio;
    }

    function getPriceFromTick(int24 _tick) internal pure returns (UD60x18 price) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(1e18, FixedPoint96.Q96, priceX96));
    }

    function getTickFromPrice(UD60x18 price) internal pure returns (int24 tick) {
        UD60x18 sqrtPrice = price.sqrt();
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
            currentTickLimits.minSqrtRatio = TickMath.getSqrtRatioAtTick(currentTickLimits.minTick);
        } else {
            currentTickLimits.minTick = self.mutableConfig.minTickAllowed;
            currentTickLimits.minSqrtRatio = self.minSqrtRatioAllowed;
        }

        if (dynamicMaxTick < self.mutableConfig.maxTickAllowed) {
            currentTickLimits.maxTick = dynamicMaxTick;
            currentTickLimits.maxSqrtRatio = TickMath.getSqrtRatioAtTick(currentTickLimits.maxTick);
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
        require(tickLower >= TickMath.MIN_TICK_LIMIT, "TLML");
        require(tickUpper <= TickMath.MAX_TICK_LIMIT, "TUML");
    }

    function dynamicTickLimits(
        UD60x18 markPrice, UD60x18 markPriceBand
    ) internal pure returns (int24 dynamicMinTick, int24 dynamicMaxTick) {
        UD60x18 minPrice = (markPrice.gt(markPriceBand)) ? markPrice.sub(markPriceBand) : ZERO;
        UD60x18 maxPrice = markPrice.add(markPriceBand);
        
        dynamicMinTick = getTickFromPrice(maxPrice);
        dynamicMaxTick = getTickFromPrice(minPrice);
    }

    function checksBeforeSwap(
        DatedIrsVamm.Data storage self,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bool isFT,
        uint160 currentMinSqrtRatio,
        uint160 currentMaxSqrtRatio
    ) internal view {

        if (amountSpecified == 0) {
            revert VammCustomErrors.IRSNotionalAmountSpecifiedMustBeNonZero();
        }

        /// @dev if a trader is an FT, they consume fixed in return for variable
        /// @dev Movement from right to left along the VAMM, hence the sqrtPriceLimitX96 needs to be higher 
        // than the current sqrtPriceX96, but lower than the MAX_SQRT_RATIO
        /// @dev if a trader is a VT, they consume variable in return for fixed
        /// @dev Movement from left to right along the VAMM, hence the sqrtPriceLimitX96 needs to be lower 
        // than the current sqrtPriceX96, but higher than the MIN_SQRT_RATIO

        require(
            isFT
                ? sqrtPriceLimitX96 > self.vars.sqrtPriceX96 &&
                    sqrtPriceLimitX96 < currentMaxSqrtRatio
                : sqrtPriceLimitX96 < self.vars.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > currentMinSqrtRatio,
            "SPL"
        );
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