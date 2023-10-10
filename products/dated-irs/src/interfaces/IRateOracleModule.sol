/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { Market } from "../storage/Market.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/// @title Interface for the module for managing rate oracles connected to the Dated IRS Market Manager
interface IRateOracleModule {
    /**
     * @notice Requests a rate index snapshot at a maturity timestamp of a given interest rate market (e.g. aUSDC lend)
     * @param marketId Id of the market (e.g. aUSDC lend) for which we're requesting a rate index value
     * @param maturityTimestamp Maturity Timestamp of a given irs market that's requesting the index value for settlement purposes
     * @return rateIndexMaturity Rate index at the requested maturityTimestamp
     */
    function getRateIndexMaturity(uint128 marketId, uint32 maturityTimestamp) external view returns (UD60x18 rateIndexMaturity);

    /**
     * @notice Requests the current rate index, or the index at maturity if we are past maturity, of a given interest rate market
     * (e.g. aUSDC borrow)
     * @param marketId Id of the market (e.g. aUSDC lend) for which we're requesting the current rate index value
     * @return rateIndexCurrent Rate index at the current timestamp or at maturity time (whichever comes earlier)
     */
    function getRateIndexCurrent(uint128 marketId) external view returns (UD60x18 rateIndexCurrent);

    /**
     * @notice Get the rate oracle configuration for a given market
     * @param marketId Market Id
     * @return rateOracleConfig The rate oracle configuration
     */
    function getRateOracleConfiguration(uint128 marketId) external view returns (Market.RateOracleConfiguration memory);

    /**
     * @notice Set rate oracle configuration for a given market
     * @param marketId Market Id
     * @param rateOracleConfig Rate Oracle Configuration
     */
    function setRateOracleConfiguration(uint128 marketId, Market.RateOracleConfiguration memory rateOracleConfig) external;

    /**
     * @notice Update the rate index at maturity cache for a given marketId & maturity timestamp
     * @param marketId market id
     * @param maturityTimestamp maturity timestap for which we want to update cached variable liquidity index
     */
    function updateRateIndexAtMaturityCache(uint128 marketId, uint32 maturityTimestamp) external;

    /**
     * @notice Backfill the rate index at maturity cache for a given marketId & maturity timestamp
     * @param marketId market id
     * @param maturityTimestamp maturity timestamp for which we want to backfill cached variable liquidity index
     * @param rateIndexAtMaturity rate index at maturity that is being backfilled for a given marketId & maturity timestamp
     */
    function backfillRateIndexAtMaturityCache(uint128 marketId, uint32 maturityTimestamp,
        UD60x18 rateIndexAtMaturity) external;
}
