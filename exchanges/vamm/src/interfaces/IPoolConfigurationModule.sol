// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../storage/PoolConfiguration.sol";

interface IPoolConfigurationModule {

  /// @notice Pausing or unpausing trading activity on the vamm
  /// @param paused True if the desire is to pause the vamm, and false inversely
  function setPauseState(bool paused) external;

  /// @notice Setting the Market Manager (instrument) address
  /// @param marketManagerAddress Address of the MarketManager proxy
  function setMarketManagerAddress(address marketManagerAddress) external;

  /// @notice Setting limit of maker positions per account
  /// @param limit Maximum number of maker positions an acccount can have
  function setMakerPositionsPerAccountLimit(uint256 limit) external;

  /// @return Pool configuration data
  function getPoolConfiguration() external pure returns (PoolConfiguration.Data memory);
}