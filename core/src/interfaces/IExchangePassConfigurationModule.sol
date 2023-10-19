/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ExchangePassConfiguration} from "../storage/ExchangePassConfiguration.sol";


/**
 * @title Module for configuring the exchange pass nft
 * @notice Allows the owner to configure the exchange pass nft
 */
interface IExchangePassConfigurationModule {

    /**
     * @notice Creates or updates the exchange pass configuration
     * @param config The ExchangePassConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {ExchangePassConfigurationUpdated} event.
     *
     */
    function configureExchangePass(ExchangePassConfiguration.Data memory config) external;


    /**
     * @notice Returns information on protocol-wide exchange pass configuration
     * @return config The configuration object describing the exchange pass configuration
     */
    function getExchangePassConfiguration() external view returns (ExchangePassConfiguration.Data memory config);
}
