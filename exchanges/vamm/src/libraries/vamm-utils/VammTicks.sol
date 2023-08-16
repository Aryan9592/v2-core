//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../ticks/Tick.sol";

import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";

import "../../storage/DatedIrsVamm.sol";
import "../errors/VammCustomErrors.sol";
import "../math/FixedPoint96.sol";
import "../math/FullMath.sol";

/**
 * @title Tracks configurations for dated irs markets
 */
library VammTicks {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VammTicks for DatedIrsVamm.Data;

    function getPriceFromTick(DatedIrsVamm.Data storage self, int24 _tick) internal view returns (UD60x18 price) {
        uint160 sqrtPriceX96 = self.getSqrtRatioAtTickSafe(_tick);
        uint256 priceX96 = FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, FixedPoint96.Q96);
        return UD60x18.wrap(FullMath.mulDiv(1e18, FixedPoint96.Q96, priceX96));
    }

    /// @dev Common checks for valid tick inputs inside the min & max ticks
    function checkTicksInRange(DatedIrsVamm.Data storage self, int24 tickLower, int24 tickUpper) internal view {
        require(tickLower < tickUpper, "TLUR");
        require(tickLower >= self.mutableConfig.minTick, "TLMR");
        require(tickUpper <= self.mutableConfig.maxTick, "TUMR");
    }

    /// @dev Common checks for valid tick inputs inside the tick limits
    function checkTicksLimits(int24 tickLower, int24 tickUpper) internal pure {
        require(tickLower < tickUpper, "TLUL");
        require(tickLower >= TickMath.MIN_TICK_LIMIT, "TLML");
        require(tickUpper <= TickMath.MAX_TICK_LIMIT, "TUML");
    }

    function checksBeforeSwap(
        DatedIrsVamm.Data storage self,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bool isFT
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
                    sqrtPriceLimitX96 < self.maxSqrtRatio
                : sqrtPriceLimitX96 < self.vars.sqrtPriceX96 &&
                    sqrtPriceLimitX96 > self.minSqrtRatio,
            "SPL"
        );
    }

    function getSqrtRatioAtTickSafe(DatedIrsVamm.Data storage self, int24 tick) internal view returns (uint160 sqrtPriceX96){
        uint256 absTick = tick < 0
            ? uint256(-int256(tick))
            : uint256(int256(tick));
        require(absTick <= uint256(int256(self.mutableConfig.maxTick)), "T");

        sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
    }

    function getTickAtSqrtRatioSafe(DatedIrsVamm.Data storage self, uint160 sqrtPriceX96) internal view returns (int24 tick){
        // second inequality must be < because the price can never reach the price at the max tick
        require(
            sqrtPriceX96 >= self.minSqrtRatio &&
                sqrtPriceX96 < self.maxSqrtRatio,
            "R"
        );

        tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
    }
}
