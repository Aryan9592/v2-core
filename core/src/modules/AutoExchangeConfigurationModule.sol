/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IAutoExchangeConfigurationModule.sol";
import "../storage/AutoExchangeConfiguration.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring protocol-wide auto-exchange configuration parameters
 * @dev See IAutoExchangeConfigurationModule
 */
contract AutoExchangeConfigurationModule is IAutoExchangeConfigurationModule {

    /**
     * @inheritdoc IAutoExchangeConfigurationModule
     */
    function configureAutoExchange(AutoExchangeConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        AutoExchangeConfiguration.set(config);
        emit AutoExchangeConfigured(config, block.timestamp);
    }


    /**
     * @inheritdoc IAutoExchangeConfigurationModule
     */
    function getAutoExchangeConfiguration() external pure returns (AutoExchangeConfiguration.Data memory config) {
        return AutoExchangeConfiguration.load();
    }

}
