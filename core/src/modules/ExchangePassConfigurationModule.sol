/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IExchangePassConfigurationModule} from "../interfaces/IExchangePassConfigurationModule.sol";
import {ExchangePassConfiguration} from "../storage/ExchangePassConfiguration.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";


/**
 * @title Module for exchange pass nft configuration
 * @dev See IExchangePassConfigurationModule
*/
contract ExchangePassConfigurationModule is IExchangePassConfigurationModule {

    /**
     * @inheritdoc IExchangePassConfigurationModule
     */
    function configureExchangePass(ExchangePassConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        ExchangePassConfiguration.set(config);
    }


    /**
     * @inheritdoc IExchangePassConfigurationModule
     */
    function getExchangePassConfiguration() external view returns (ExchangePassConfiguration.Data memory config) {
        return ExchangePassConfiguration.exists();
    }
}
