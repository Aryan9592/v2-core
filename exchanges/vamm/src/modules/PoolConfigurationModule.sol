// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.13;

import { IPoolConfigurationModule } from "../interfaces/IPoolConfigurationModule.sol";
import { PoolConfiguration } from "../storage/PoolConfiguration.sol";
import { OwnableStorage } from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

contract PoolConfigurationModule is IPoolConfigurationModule {
    /**
     * @inheritdoc IPoolConfigurationModule
     */
    function setPoolConfiguration(PoolConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        PoolConfiguration.set(config);
    }

    /**
     * @inheritdoc IPoolConfigurationModule
     */
    function getPoolConfiguration() external pure override returns (PoolConfiguration.Data memory) {
        return PoolConfiguration.load();
    }
}
