/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";

import { MarketRateOracle } from "../libraries/MarketRateOracle.sol"; 

/**
 * @title Tracks configurations and metadata for dated irs markets
 */
library Market {
    /**
     * @dev Thrown when a market cannot be found.
     */
    error MarketNotFound(uint128 marketId);

    /**
     * @dev Thrown when a market already exists.
     */
    error MarketAlreadyExists(uint128 marketId);

    /**
     * @dev Thrown when a market is created with a zero quote token address
     */
    error ZeroQuoteTokenAddress();

    /**
     * @notice Emitted when attempting to register a rate oracle with an invalid oracle address
     * @param oracleAddress Invalid oracle address
     */
    error InvalidVariableOracleAddress(address oracleAddress);

    /**
     * @notice Emitted when a market is created
     * @param id The market id
     * @param quoteToken The quote token of the market
     * @param blockTimestamp The current block timestamp.
     */
    event MarketCreated(uint128 id, address quoteToken, uint256 blockTimestamp);

    /**
     * @notice Emitted when a new market configuration is set
     * @param id The market id
     * @param marketConfiguration The new market configuration
     * @param blockTimestamp The current block timestamp
     */
    event MarketConfigUpdated(uint128 id, MarketConfiguration marketConfiguration, uint256 blockTimestamp);

    /**
     * @notice Emitted when a new rate oracle configuration is set
     * @param id The id of the market
     * @param rateOracleConfiguration The new rate oracle configuration
     * @param blockTimestamp The current block timestamp.
     */
    event MarketRateOracleConfigUpdated(uint128 id, RateOracleConfiguration rateOracleConfiguration, uint256 blockTimestamp);

    struct MarketConfiguration {
        /**
         * @dev Number of seconds in the past from which to calculate the time-weighted average fixed rate (average = geometric mean)
         */
        uint32 twapLookbackWindow;

        /**
         * @dev Maximum number of positions of an account in this market
         */
        uint256 takerPositionsPerAccountLimit;
    }

    struct RateOracleConfiguration {
        /**
         * @dev The address of the rate oracle
         */
        address oracleAddress;

        /**
         * @dev Maximum number of seconds that can elapse after maturity to cache the maturity index value
         */
        uint256 maturityIndexCachingWindowInSeconds;
    }

    struct Data {
        /**
         * @dev Id fo a given interest rate swap market
         */
        uint128 id;
        /**
         * @dev Address of the quote token.
         * @dev IRS contracts settle in the quote token
         * i.e. settlement cashflows and unrealized pnls are in quote token terms
         */
        address quoteToken;

        /**
         * @dev Market configuration
         */
        MarketConfiguration marketConfig;

        /**
         * @dev Rate Oracle configuration
         */
        RateOracleConfiguration rateOracleConfig;

        /**
         * Cache with maturity index values.
         */
        mapping(uint256 maturityTimestamp => UD60x18 rateIndex) rateIndexAtMaturity;
    }

    /**
     * @dev Loads the MarketConfiguration object for the given dated irs market id
     * @param id Id of the IRS market that we want to load the configurations for
     * @return market The CollateralConfiguration object.
     */
    function load(uint128 id) internal pure returns (Data storage market) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Market", id));
        assembly {
            market.slot := s
        }
    }

    /**
     * @dev Returns the market stored at the specified market id.
     */
    function exists(uint128 id) internal view returns (Data storage market) {
        market = load(id);

        if (id == 0 || market.id != id) {
            revert MarketNotFound(id);
        }
    }

    /**
     * @dev Creates a dated interest rate swap market
     * @param id The id of the market
     * @param quoteToken The quote token of the market
     */
    function create(uint128 id, address quoteToken) internal {
        if (quoteToken == address(0)) {
            revert ZeroQuoteTokenAddress();
        }

        Data storage market = load(id);

        if (market.quoteToken != address(0)) {
            revert MarketAlreadyExists(id);
        }

        market.id = id;
        market.quoteToken = quoteToken;

        emit MarketCreated(id, quoteToken, block.timestamp);
    }

    function setMarketConfiguration(Data storage self, MarketConfiguration memory marketConfig) internal {
        self.marketConfig = marketConfig;
        emit MarketConfigUpdated(self.id, marketConfig, block.timestamp);
    }

    function setRateOracleConfiguration(Data storage self, RateOracleConfiguration memory rateOracleConfig) internal {
        if (!MarketRateOracle.validateOracleInterface(rateOracleConfig.oracleAddress)) {
            revert InvalidVariableOracleAddress(rateOracleConfig.oracleAddress);
        }

        self.rateOracleConfig = rateOracleConfig;
        emit MarketRateOracleConfigUpdated(self.id, rateOracleConfig, block.timestamp);
    }

    function backfillRateIndexAtMaturityCache(Data storage self, uint32 maturityTimestamp, UD60x18 rateIndexAtMaturity) internal {
        MarketRateOracle.backfillRateIndexAtMaturityCache(self, maturityTimestamp, rateIndexAtMaturity);
    }

    function updateRateIndexAtMaturityCache(Data storage self, uint32 maturityTimestamp) internal {
        MarketRateOracle.updateRateIndexAtMaturityCache(self, maturityTimestamp);
    }

    function getRateIndexCurrent(Data storage self) internal view returns (UD60x18 rateIndexCurrent) {
        return MarketRateOracle.getRateIndexCurrent(self);
    }

    function getRateIndexMaturity(Data storage self, uint32 maturityTimestamp) internal view returns (UD60x18 rateIndexMaturity) {
        return MarketRateOracle.getRateIndexMaturity(self, maturityTimestamp);
    }

    function updateOracleStateIfNeeded(Data storage self) internal {
        MarketRateOracle.updateOracleStateIfNeeded(self);
    }
}
