/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IRiskConfigurationModule.sol";
import "../storage/Market.sol";
import "../storage/CollateralPool.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring protocol-wide and market level risk parameters
 * @dev See IRiskConfigurationModule
 */
contract RiskConfigurationModule is IRiskConfigurationModule {
    using CollateralPool for CollateralPool.Data;
    using Market for Market.Data;

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureMarketRisk(uint128 marketId, Market.RiskConfiguration memory config) external override {
        Market.Data storage market = Market.exists(marketId);
        market.getCollateralPool().onlyOwner();
        market.setRiskConfiguration(config);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureCollateralPoolRisk(uint128 collateralPoolId, CollateralPool.RiskConfiguration memory config) external override {
        CollateralPool.Data storage collateralPool = CollateralPool.exists(collateralPoolId);
        collateralPool.onlyOwner();
        collateralPool.setRiskConfiguration(config);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getMarketRiskConfiguration(uint128 marketId)
        external
        view
        override
        returns (Market.RiskConfiguration memory)
    {
        return Market.exists(marketId).riskConfig;
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getCollateralPoolRiskConfiguration(uint128 collateralPoolId) 
        external 
        view 
        returns (CollateralPool.RiskConfiguration memory) 
    {
        return CollateralPool.exists(collateralPoolId).riskConfig;
    }
}
