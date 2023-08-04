/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IRiskConfigurationModule.sol";
import "../storage/Market.sol";
import "../storage/ProtocolRiskConfiguration.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring protocol-wide and market level risk parameters
 * @dev See IRiskConfigurationModule
 */
contract RiskConfigurationModule is IRiskConfigurationModule {
    using Market for Market.Data;

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureMarketRisk(uint128 marketId, Market.MarketRiskConfiguration memory config) external override {
        OwnableStorage.onlyOwner();
        Market.exists(marketId).setRiskConfiguration(config);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureProtocolRisk(ProtocolRiskConfiguration.Data memory config) external override {
        OwnableStorage.onlyOwner();
        ProtocolRiskConfiguration.set(config);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getMarketRiskConfiguration(uint128 marketId)
        external
        view
        override
        returns (Market.MarketRiskConfiguration memory)
    {
        return Market.exists(marketId).riskConfig;
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getProtocolRiskConfiguration() external pure returns (ProtocolRiskConfiguration.Data memory) {
        return ProtocolRiskConfiguration.load();
    }
}
