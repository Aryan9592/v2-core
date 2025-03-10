/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { IPool } from "../interfaces/IPool.sol";
import { IRateOracle } from "../interfaces/IRateOracle.sol";
import { MarketRateOracle } from "../libraries/MarketRateOracle.sol";
import { RateOracleObservation } from "../libraries/DataTypes.sol";

import { IERC165 } from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";

/**
 * @title Tracks configurations and metadata for dated irs markets
 */
library Market {
    using Market for Market.Data;

    /// Market types
    bytes32 internal constant LINEAR_MARKET = "linear";
    bytes32 internal constant COMPOUNDING_MARKET = "compounding";

    /**
     * @dev Thrown when a market is created with an unsupported market type
     */
    error UnsupportedMarketType(bytes32 marketType);

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
     * Emitted when attempting to register a pool address with an invalid pool address
     * @param poolAddress Invalid pool address
     */
    error InvalidPoolAddress(address poolAddress);

    /**
     * @notice Emitted when attempting to register a rate oracle with an invalid oracle address
     * @param oracleAddress Invalid oracle address
     */
    error InvalidVariableOracleAddress(address oracleAddress);

    /**
     * @notice Thrown when attempting to set a phi that is out of bounds.
     */
    error PhiOutOfBounds(uint128 marketId, uint32 maturityTimestamp, UD60x18 phi);

    /**
     * @notice Thrown when attempting to set a beta that is out of bounds.
     */
    error BetaOutOfBounds(uint128 marketId, uint32 maturityTimestamp, UD60x18 beta);

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
    event MarketRateOracleConfigUpdated(
        uint128 id, RateOracleConfiguration rateOracleConfiguration, uint256 blockTimestamp
    );

    /**
     * @notice Emitted when a new market configuration is set
     * @param id The market id
     * @param maturityTimestamp The maturityTimestamp
     * @param marketMaturityConfiguration The new market maturity configuration
     * @param blockTimestamp The current block timestamp
     */
    event MarketMaturityConfigUpdated(
        uint128 id,
        uint32 maturityTimestamp,
        MarketMaturityConfiguration marketMaturityConfiguration,
        uint256 blockTimestamp
    );

    struct FeeConfiguration {
        /**
         * @dev Atomic Maker Fee is multiplied by the annualised notional liquidity provided via an on-chain exchange
         * @dev to derive the maker fee charged by the protocol.
         */
        UD60x18 atomicMakerFee;
        /**
         * @dev Atomic Taker Fee is multiplied by the annualised notional traded
         * @dev to derive the taker fee charged by the protocol.
         */
        UD60x18 atomicTakerFee;
    }

    struct MarketConfiguration {
        /**
         * @dev Address of the pool address the market is linked to
         */
        address poolAddress;
        /**
         * @dev Number of seconds in the past from which to calculate the time-weighted average fixed rate (average =
         * geometric mean)
         */
        uint32 twapLookbackWindow;
        /**
         * Mark price band used to compute dynamic price limits
         */
        UD60x18 markPriceBand;
        /**
         * @dev Market fee configurations for protocol
         */
        FeeConfiguration protocolFeeConfig;
        /**
         * @dev Maximum number of positions of an account in this market
         */
        uint256 takerPositionsPerAccountLimit;
        /**
         * @dev Maximum size allowed of an account's position
         */
        uint256 positionSizeUpperLimit;
        /**
         * @dev Minimum size allowed of an account's position
         */
        uint256 positionSizeLowerLimit;
        /**
         * @dev Maximum amount of open interest allowed in this market
         */
        uint256 openInterestUpperLimit;
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

    struct MarketMaturityConfiguration {
        /**
         * @dev Risk matrix row id
         */
        uint256 riskMatrixRowId;
        /**
         * @dev Original tenor in seconds
         */
        uint256 tenorInSeconds;
        /**
         * @dev The phi value used to compute percentual slippage
         */
        UD60x18 phi;
        /**
         * @dev The beta value used to compute percentual slippage
         */
        UD60x18 beta;
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
         * @dev Market type, either linear or compounding.
         */
        bytes32 marketType;
        /**
         * @dev Market configuration
         */
        MarketConfiguration marketConfig;
        /**
         * @dev Rate Oracle configuration
         */
        RateOracleConfiguration rateOracleConfig;
        /**
         * @dev Market Maturity configuration
         */
        mapping(uint32 maturityTimestamp => MarketMaturityConfiguration marketMaturityConfig) marketMaturityConfigs;
        /**
         * @dev Duration of ADL blendin period, in seconds
         */
        // todo: setter and getter?
        uint256 adlBlendingDurationInSeconds;
        /**
         * Cache with maturity index values.
         */
        mapping(uint32 maturityTimestamp => UD60x18 rateIndex) rateIndexAtMaturity;
        /**
         * Cache with maturity index values.
         */
        mapping(uint32 maturityTimestamp => uint256 notional) notionalTracker;
    }

    /**
     * @dev Loads the MarketConfiguration object for the given dated irs market id
     * @param id Id of the IRS market that we want to load the configurations for
     * @return market The CollateralConfiguration object.
     */
    function load(uint128 id) private pure returns (Data storage market) {
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
    function create(uint128 id, address quoteToken, bytes32 marketType) internal {
        if (quoteToken == address(0)) {
            revert ZeroQuoteTokenAddress();
        }

        if (marketType != LINEAR_MARKET && marketType != COMPOUNDING_MARKET) {
            revert UnsupportedMarketType(marketType);
        }

        Data storage market = load(id);

        if (market.quoteToken != address(0)) {
            revert MarketAlreadyExists(id);
        }

        market.id = id;
        market.quoteToken = quoteToken;
        market.marketType = marketType;

        emit MarketCreated(id, quoteToken, block.timestamp);
    }

    function setMarketConfiguration(Data storage self, MarketConfiguration memory marketConfig) internal {
        if (!IERC165(marketConfig.poolAddress).supportsInterface(type(IPool).interfaceId)) {
            revert InvalidPoolAddress(marketConfig.poolAddress);
        }

        self.marketConfig = marketConfig;
        emit MarketConfigUpdated(self.id, marketConfig, block.timestamp);
    }

    function setRateOracleConfiguration(Data storage self, RateOracleConfiguration memory rateOracleConfig) internal {
        if (!IERC165(rateOracleConfig.oracleAddress).supportsInterface(type(IRateOracle).interfaceId)) {
            revert InvalidVariableOracleAddress(rateOracleConfig.oracleAddress);
        }

        self.rateOracleConfig = rateOracleConfig;
        emit MarketRateOracleConfigUpdated(self.id, rateOracleConfig, block.timestamp);
    }

    function setMarketMaturityConfiguration(
        Data storage self,
        uint32 maturityTimestamp,
        MarketMaturityConfiguration memory marketMaturityConfig
    )
        internal
    {
        self.marketMaturityConfigs[maturityTimestamp] = marketMaturityConfig;
        emit MarketMaturityConfigUpdated(self.id, maturityTimestamp, marketMaturityConfig, block.timestamp);
    }

    function backfillRateIndexAtMaturityCache(
        Data storage self,
        uint32 maturityTimestamp,
        UD60x18 rateIndexAtMaturity
    )
        internal
    {
        MarketRateOracle.backfillRateIndexAtMaturityCache(self, maturityTimestamp, rateIndexAtMaturity);
    }

    function updateRateIndexAtMaturityCache(Data storage self, uint32 maturityTimestamp) internal {
        MarketRateOracle.updateRateIndexAtMaturityCache(self, maturityTimestamp);
    }

    function getRateIndexCurrent(Data storage self) internal view returns (UD60x18) {
        return MarketRateOracle.getRateIndexCurrent(self);
    }

    function getRateIndexMaturity(Data storage self, uint32 maturityTimestamp) internal view returns (UD60x18) {
        return MarketRateOracle.getRateIndexMaturity(self, maturityTimestamp);
    }

    function getLatestRateIndex(
        Data storage self,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (RateOracleObservation memory)
    {
        return MarketRateOracle.getLatestRateIndex(self, maturityTimestamp);
    }

    function updateOracleStateIfNeeded(Data storage self) internal {
        MarketRateOracle.updateOracleStateIfNeeded(self);
    }

    function exposureFactor(Data storage self) internal view returns (UD60x18 factor) {
        if (self.marketType == LINEAR_MARKET) {
            return UNIT;
        }

        if (self.marketType == COMPOUNDING_MARKET) {
            UD60x18 currentLiquidityIndex = self.getRateIndexCurrent();
            return currentLiquidityIndex;
        }

        revert UnsupportedMarketType(self.marketType);
    }
}
