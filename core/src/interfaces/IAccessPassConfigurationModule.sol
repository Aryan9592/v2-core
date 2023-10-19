/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/AccessPassConfiguration.sol";

/**
 * @title Module for configuring the access pass nft
 * @notice Allows the owner to configure the access pass nft
 */
interface IAccessPassConfigurationModule {

    /**
     * @notice Creates or updates the access pass configuration
     * @param config The AccessPassConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     *
     * Emits a {AccessPassConfigurationUpdated} event.
     *
     */
    function configureAccessPass(AccessPassConfiguration.Data memory config) external;


    /**
     * @notice Returns information on protocol-wide access pass configuration
     * @return config The configuration object describing the access pass configuration
     */
    function getAccessPassConfiguration() external view returns (AccessPassConfiguration.Data memory config);
}
