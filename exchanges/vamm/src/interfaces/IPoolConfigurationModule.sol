// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../storage/PoolConfiguration.sol";

interface IPoolConfigurationModule {
  /// @notice Setting pool configuration
  /// @param config The Pool Configuration object describing the new configuration.
  function setPoolConfiguration(PoolConfiguration.Data memory config) external;

  /// @return Pool configuration data
  function getPoolConfiguration() external pure returns (PoolConfiguration.Data memory);
}