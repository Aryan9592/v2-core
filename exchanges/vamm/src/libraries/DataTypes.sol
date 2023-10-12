//SPDX-License-Identifier: MIT

pragma solidity >=0.8.13;

import "@voltz-protocol/products-dated-irs/src/libraries/DataTypes.sol";

/// @dev the top level state of the swap, the results of which are recorded in storage at the end
struct SwapState {
    /// @dev the amount remaining to be swapped in/out of the input/output asset
    int256 amountSpecifiedRemaining;
    /// @dev current sqrt(price)
    uint160 sqrtPriceX96;
    /// @dev the tick associated with the current price
    int24 tick;
    PositionBalances growthGlobalX128;
    PositionBalances tokenDeltaCumulative;
    /// @dev the current liquidity in range
    uint128 liquidity;
}

struct SwapStepComputations {
    /// @dev the price at the beginning of the step
    uint160 sqrtPriceStartX96;
    /// @dev the next tick to swap to from the current tick in the swap direction
    int24 tickNext;
    /// @dev whether tickNext is initialized or not
    bool initialized;
    /// @dev sqrt(price) for the next tick (1/0)
    uint160 sqrtPriceNextX96;
    /// @dev how much is being swapped in in this step
    uint256 amountIn;
    /// @dev how much is being swapped out
    uint256 amountOut;
    UD60x18 averagePrice;
    PositionBalances tokenDeltas;
}
