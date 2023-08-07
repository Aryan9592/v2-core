/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/AutoExchangeConfiguration.sol";


/**
 * @title Module for configuring auto-exchange parameters
 * @notice Allows the owner to configure auto-exchange parameters
 */
interface IAutoExchangeConfigurationModule {
    
    /**
     * @notice Creates or updates the auto-exchange configuration on the protocol (i.e. system-wide) level
     * @param config The AutoExchangeConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {AutoExchangeConfigured} event.
     *
     */
    function configureAutoExchange(AutoExchangeConfiguration.Data memory config) external;


    /**
     * @notice Returns detailed information on protocol-wide auto-exchange configuration
     * @return config The configuration object describing the protocol-wide auto-exchange configuration.
     */
    function getAutoExchangeConfiguration() external pure returns (AutoExchangeConfiguration.Data memory config);

}