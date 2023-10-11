/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { Market } from "../storage/Market.sol";

/**
 * @title Module for configuring a market
 * @notice Allows the owner to configure the quote token of the given market
 */

interface IMarketConfigurationModule {
    /**
     * @notice Creates a market
     * @param marketId The market id
     * @param quoteToken The quote token of the market
     * @param marketType The type of the market
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the dated irs instrument.
     *
     * Emits a {MarketCreated} event.
     *
     */
    function createMarket(uint128 marketId, address quoteToken, bytes32 marketType) external;

    /**
     * @notice Sets the market configuration
     * @param marketId The market id
     * @param marketConfig The new market configuration
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the dated irs instrument.
     *
     * Emits a {MarketConfigUpdated} event.
     *
     */
    function setMarketConfiguration(uint128 marketId, Market.MarketConfiguration memory marketConfig) external;

    // todo: add natspec
    function setRiskMatrixRowId(uint128 marketId, uint32 maturityTimestamp, uint256 rowId) external;

    /**
     * @notice Returns the market configuration
     * @return config The market configuration
     */
    function getMarketConfiguration(uint128 marketId) external view returns (Market.MarketConfiguration memory);

    // todo: add natspec
    function getRiskMatrixRowId(uint128 marketId, uint32 maturityTimestamp) external view returns (uint256);

    /**
     * @notice Returns the market type
     * @return marketType The market type
     */
    function getMarketType(uint128 marketId) external view returns (bytes32);
}
