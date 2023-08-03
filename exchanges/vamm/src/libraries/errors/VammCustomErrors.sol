// SPDX-License-Identifier: Apache-2.0

pragma solidity >=0.8.13;

interface VammCustomErrors {
   
   /// @dev Thrown when a zero address was passed as a function parameter (0x0000000000000000000000000000000000000000).
   error ZeroAddress();

   /// @dev Thrown when a change is expected but none is detected.
   error NoChange();

   /// The operation is not authorized by the executing adddress
   error Unauthorized(address unauthorizedAddr);

   /// Only one VAMM can exist for any given {market, maturity}
   error MarketAndMaturityCombinaitonAlreadyExists(uint128 marketId, uint32 maturityTimestamp);

   /// No VAMM currently exists for the specified {market, maturity}
   error MarketAndMaturityCombinaitonNotSupported(uint128 marketId, uint32 maturityTimestamp);

   /// @dev If the sqrt price of the vamm is non-zero before a vamm is initialized, it has already been initialized. Initialization can only be done once.
   error ExpectedSqrtPriceZeroBeforeInit(uint160 sqrtPriceX96);

   /// @dev If the sqrt price of the vamm is zero, this makes no sense and does not allow sqrtPriceX96 to double as an "already initialized" flag.
      error ExpectedNonZeroSqrtPriceForInit(uint160 sqrtPriceX96);

   /// @dev Error which ensures the amount of notional specified when initiating an IRS contract (via the swap function in the vamm) is non-zero
   error IRSNotionalAmountSpecifiedMustBeNonZero();

   /// @dev Error which ensures the VAMM is unlocked
   error CanOnlyTradeIfUnlocked();

   /// @dev Error which ensures the VAMM is unlocked
   error CanOnlyUnlockIfLocked();

   /// @dev Error which ensures the VAMM maturity is in the future
   error MaturityMustBeInFuture(uint256 currentTime, uint256 requestedMaturity);

   /**
     * @dev Thrown when a specified vamm is not found.
     */
    error IRSVammNotFound(uint128 vammId);

    /**
     * @dev Thrown when Twap order size is 0 and it tries to adjust for spread or price impact
     */
    error TwapNotAdjustable();

    /**
     * @dev Thrown when price impact configuration is larger than 1 in wad
     */
    error PriceImpactOutOfBounds();

    /**
     * @dev Thrown when specified ticks excees limits set in TickMath
     * or the current tick is outside of the range
     */
    error ExceededTickLimits(int24 minTick, int24 maxTick);

    /**
     * @dev Thrown when specified ticks are not symmetric around 0
     */
    error AsymmetricTicks(int24 minTick, int24 maxTick);

    /**
     * @dev Thrown when the number of positions per account exceeded the limit.
     */
    error TooManyLpPositions(uint128 accountId);
}
