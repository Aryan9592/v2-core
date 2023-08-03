/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IRiskConfigurationModule.sol";
import "../storage/MarketRiskConfiguration.sol";
import "../storage/ProtocolRiskConfiguration.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring protocol-wide and market level risk parameters
 * @dev See IRiskConfigurationModule
 */
contract RiskConfigurationModule is IRiskConfigurationModule {
    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureMarketRisk(MarketRiskConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        MarketRiskConfiguration.set(config);
        emit MarketRiskConfigured(config, block.timestamp);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureProtocolRisk(ProtocolRiskConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        ProtocolRiskConfiguration.set(config);
        emit ProtocolRiskConfigured(config, block.timestamp);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getMarketRiskConfiguration(uint128 marketId)
        external
        pure
        override
        returns (MarketRiskConfiguration.Data memory config)
    {
        return MarketRiskConfiguration.load(marketId);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getProtocolRiskConfiguration() external pure returns (ProtocolRiskConfiguration.Data memory config) {
        return ProtocolRiskConfiguration.load();
    }
}
