/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Market.sol";
import "../storage/ProtocolRiskConfiguration.sol";

/**
 * @title Module for configuring protocol and market wide risk parameters
 * @notice Allows the owner to configure risk parameters at protocol and market wide level
 */
interface IRiskConfigurationModule {
    /**
     * @notice Creates or updates the configuration for the given `marketId`
     * @param config The MarketConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {MarketRiskConfigured} event.
     *
     */
    function configureMarketRisk(uint128 marketId, Market.MarketRiskConfiguration memory config) external;

    /**
     * @notice Returns detailed information pertaining the specified marketId
     * @param marketId Id that uniquely identifies the market (e.g. aUSDC lend) for which we want to query the risk config
     * @return config The configuration object describing the given marketId
     */
    function getMarketRiskConfiguration(uint128 marketId)
        external
        view
        returns (Market.MarketRiskConfiguration memory config);

    /**
     * @notice Creates or updates the configuration on the protocol (i.e. system-wide) level
     * @param config The ProtocolConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {ProtocolRiskConfigured} event.
     *
     */
    function configureProtocolRisk(ProtocolRiskConfiguration.Data memory config) external;

    /**
     * @notice Returns detailed information on protocol-wide risk configuration
     * @return config The configuration object describing the protocol-wide risk configuration
     */
    function getProtocolRiskConfiguration() external pure returns (ProtocolRiskConfiguration.Data memory config);
}
