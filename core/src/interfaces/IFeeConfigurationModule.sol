/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Market.sol";

/**
 * @title Module for configuring (protocol and) market wide risk parameters
 * @notice Allows the owner to configure risk parameters at (protocol and) market wide level
 */
interface IFeeConfigurationModule {
    /**
     * @notice Creates or updates the fee configuration for the given `marketId`
     * @param config The MarketFeeConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {MarketFeeConfigured} event.
     *
     */
    function configureMarketFee(uint128 marketId, Market.MarketFeeConfiguration memory config) external;

    /**
     * @notice Returns detailed information pertaining the specified marketId
     * @param marketId Id that uniquely identifies the market (e.g. aUSDC lend) for which we want to query the risk config
     * @return config The fee configuration object describing the given marketId
     */
    function getMarketFeeConfiguration(uint128 marketId)
        external
        view
        returns (Market.MarketFeeConfiguration memory config);
}
