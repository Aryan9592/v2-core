// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IPoolConfigurationModule.sol";

import {PoolConfiguration} from "../storage/PoolConfiguration.sol";
import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

contract PoolConfigurationModule is IPoolConfigurationModule {
  using PoolConfiguration for PoolConfiguration.Data;

  function setPoolConfiguration(PoolConfiguration.Data memory config) external override {
    OwnableStorage.onlyOwner();
    PoolConfiguration.set(config);
  }

  function getPoolConfiguration() external pure override returns (PoolConfiguration.Data memory) {
     return PoolConfiguration.load();
  }
}