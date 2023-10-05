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
    function configureCollateralPoolRisk(uint128 collateralPoolId, CollateralPool.RiskConfiguration memory config) external override {
        CollateralPool.Data storage collateralPool = CollateralPool.exists(collateralPoolId);
        collateralPool.onlyOwner();
        collateralPool.setRiskConfiguration(config);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getCollateralPoolRiskConfiguration(uint128 collateralPoolId) 
        external 
        view
        override
        returns (CollateralPool.RiskConfiguration memory) 
    {
        return CollateralPool.exists(collateralPoolId).riskConfig;
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function configureRiskMatrix(
        uint128 collateralPoolId,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex,
        SD59x18 value
    ) external override {
        CollateralPool.Data storage collateralPool = CollateralPool.exists(collateralPoolId);
        collateralPool.onlyOwner();
        collateralPool.configureRiskMatrix(blockIndex, rowIndex, columnIndex, value);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getRiskMatrixParameter(
        uint128 collateralPoolId,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex
    ) external view override returns (SD59x18 parameter) {
        return CollateralPool.exists(collateralPoolId).getRiskMatrixParameter(blockIndex, rowIndex, columnIndex);
    }

    /**
     * @inheritdoc IRiskConfigurationModule
     */
    function getRiskMatrixParameterFromMM(
        uint128 marketId,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex
    ) external view override returns (SD59x18 parameter) {
        Market.Data storage market = Market.exists(marketId);
        uint128 collateralPoolId = market.getCollateralPool().id;
        return CollateralPool.exists(collateralPoolId).getRiskMatrixParameter(blockIndex, rowIndex, columnIndex);
    }

}
