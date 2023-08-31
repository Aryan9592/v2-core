// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

interface IPoolModule is IPool {
    /**
    * @notice Get dated IRS TWAP
    * @param marketId Id of the market for which we want to retrieve the dated IRS TWAP
    * @param maturityTimestamp Timestamp at which a given market matures
    * @param orderSizeWad The order size to use when adjusting the price for price impact or spread.
    * Must not be zero if either of the boolean params is true because it used to indicate the direction 
    * of the trade and therefore the direction of the adjustment. Function will revert if `abs(orderSize)` 
    * overflows when cast to a `U60x18`. Must have 18 decimals precision.
    * @param lookbackWindow Number of seconds in the past from which to calculate the time-weighted means
    * @param adjustForPriceImpact Whether or not to adjust the returned price by the VAMM's configured spread.
    * @param adjustForSpread Whether or not to adjust the returned price by the VAMM's configured spread.
    * @return datedIRSTwap Time Weighted Average Fixed Rate (average = geometric mean)
    */
  function getDatedIRSTwap(
    uint128 marketId,
    uint32 maturityTimestamp,
    int256 orderSizeWad,
    uint32 lookbackWindow,
    bool adjustForPriceImpact,
    bool adjustForSpread
  ) external view returns (UD60x18 datedIRSTwap);
}