/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IRateOracleModule.sol";
import {Market} from "../storage/Market.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Module for managing rate oracles connected to the Dated IRS Market
 * @dev See IRateOracleModule
 */
contract RateOracleModule is IRateOracleModule {
    using Market for Market.Data;

    /**
     * @inheritdoc IRateOracleModule
     */
    function getRateIndexCurrent(
        uint128 marketId
    )
        external
        view
        override
        returns (UD60x18 rateIndexCurrent)
    {
        return Market.exists(marketId).getRateIndexCurrent();
    }

    /**
     * @inheritdoc IRateOracleModule
     */
    function getRateIndexMaturity(
        uint128 marketId,
        uint32 maturityTimestamp
    )
        external
        view
        override
        returns (UD60x18 rateIndexMaturity)
    {
        return Market.exists(marketId).getRateIndexMaturity(maturityTimestamp);
    }

    /**
     * @inheritdoc IRateOracleModule
     */
    function getLatestRateIndex(
        uint128 marketId, 
        uint32 maturityTimestamp
    ) external view returns (RateOracleObservation memory) {
        return Market.exists(marketId).getLatestRateIndex(maturityTimestamp);
    }

    /**
    * @inheritdoc IRateOracleModule
     */
    function getRateOracleConfiguration(uint128 marketId) external view override returns (Market.RateOracleConfiguration memory) {
        return Market.exists(marketId).rateOracleConfig;
    }

    /**
     * @inheritdoc IRateOracleModule
     */
    function setRateOracleConfiguration(uint128 marketId, Market.RateOracleConfiguration memory rateOracleConfig)
    external override {
        OwnableStorage.onlyOwner();
        Market.exists(marketId).setRateOracleConfiguration(rateOracleConfig);
    }

    /**
     * @inheritdoc IRateOracleModule
     */
    function updateRateIndexAtMaturityCache(uint128 marketId, uint32 maturityTimestamp) external override {
        Market.exists(marketId).updateRateIndexAtMaturityCache(maturityTimestamp);
    }

    /**
     * @inheritdoc IRateOracleModule
     */
    function backfillRateIndexAtMaturityCache(
        uint128 marketId, 
        uint32 maturityTimestamp,
        UD60x18 rateIndexAtMaturity
    ) external override {
        OwnableStorage.onlyOwner();
        Market.exists(marketId).backfillRateIndexAtMaturityCache(maturityTimestamp, rateIndexAtMaturity);
    }
}
