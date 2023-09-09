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

    // todo: need to make sure that auto-exchange configuration is configurable on collateral pool level
    // and then update the comments accordingly
    /**
     * @notice Creates or updates the auto-exchange configuration on collateral pool level
     * @param config The AutoExchangeConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     *
     * Emits a {AutoExchangeConfigured} event.
     *
     */
    function configureAutoExchange(AutoExchangeConfiguration.Data memory config) external;


    /**
     * @notice Returns detailed information on collateral pool auto-exchange configuration
     * @return config The configuration object describing the collateral pool auto-exchange configuration.
     */
    function getAutoExchangeConfiguration() external pure returns (AutoExchangeConfiguration.Data memory config);

}