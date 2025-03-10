// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { PoolConfiguration } from "../storage/PoolConfiguration.sol";

/**
 * @title An interface for the contract that manages the pool configurations
 * @notice Contract that allows setting and retrieving the configuration of the pool
 */
interface IPoolConfigurationModule {
    /**
     * @notice Setting pool configuration
     * @param config The Pool Configuration object describing the new configuration
     */
    function setPoolConfiguration(PoolConfiguration.Data memory config) external;

    /**
     * @dev Returns pool configuration data
     */
    function getPoolConfiguration() external pure returns (PoolConfiguration.Data memory);
}
