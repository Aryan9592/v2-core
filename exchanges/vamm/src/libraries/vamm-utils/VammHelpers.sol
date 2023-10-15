// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { TickMath } from "../ticks/TickMath.sol";
import { FullMath } from "../math/FullMath.sol";
import { FixedPoint96 } from "../math/FixedPoint96.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { UD60x18, ZERO, ud, convert } from "@prb/math/UD60x18.sol";

using SafeCastU256 for uint256;
using SafeCastI256 for int256;

/**
 * @notice Transforms liquidity into base and quote
 * @param liquidity Amount of liquidity
 * @param tickLower The lower tick of the range
 * @param tickUpper The upper tick of the range
 * @return absBase Absolute base amount
 * @return absUnbalancedQuote Absolute quote amount
 */
function amountsFromLiquidity(
    uint128 liquidity,
    int24 tickLower,
    int24 tickUpper
)
    pure
    returns (uint256 absBase, uint256 absUnbalancedQuote)
{
    uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

    if (sqrtRatioAX96 > sqrtRatioBX96) {
        (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
    }

    absBase = FullMath.mulDiv(liquidity, sqrtRatioBX96 - sqrtRatioAX96, FixedPoint96.Q96);

    absUnbalancedQuote =
        FullMath.mulDiv(FullMath.mulDiv(absBase, FixedPoint96.Q96, sqrtRatioBX96), FixedPoint96.Q96, sqrtRatioAX96);
}

/**
 * @notice Transforms base into liquidity
 * @param base Amount of base tokens
 * @param tickLower The lower tick of the range
 * @param tickUpper The upper tick of the range
 * @return liquidity Corresponding amount of liquidity
 */
function liquidityFromBase(int256 base, int24 tickLower, int24 tickUpper) pure returns (int128 liquidity) {
    uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(tickLower);
    uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(tickUpper);

    if (sqrtRatioAX96 > sqrtRatioBX96) {
        (sqrtRatioAX96, sqrtRatioBX96) = (sqrtRatioBX96, sqrtRatioAX96);
    }

    uint256 absBase = uint256(base > 0 ? base : -base);
    uint256 absLiquidity = FullMath.mulDiv(absBase, FixedPoint96.Q96, sqrtRatioBX96 - sqrtRatioAX96);

    return base > 0 ? absLiquidity.toInt().to128() : -(absLiquidity.toInt().to128());
}

/**
 * @notice Computes the VAMM price based on base and unbalanced quote
 * @param base Base amount
 * @param unbalancedQuote Unbalanced quote amount
 * @return price Resulting VAMM price
 */
function calculatePrice(uint256 base, uint256 unbalancedQuote) pure returns (UD60x18) {
    return ud(unbalancedQuote).div(ud(base)).div(convert(100));
}

/**
 * @notice Applies the given spread on the VAMM price
 * @param price The VAMM price
 * @param spread Absolute spread value to be applied
 * @param isLPLong Trade direction, decides in which direction to apply the spread
 */
function applySpread(UD60x18 price, UD60x18 spread, bool isLPLong) pure returns (UD60x18) {
    return (isLPLong) ? ((price.lt(spread)) ? ZERO : price.sub(spread)) : price.add(spread);
}
