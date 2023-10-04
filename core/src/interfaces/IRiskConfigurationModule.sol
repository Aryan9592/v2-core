/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/CollateralPool.sol";
import "../storage/Market.sol";

/**
 * @title Module for configuring collateral pool and market wide risk parameters
 * @notice Allows the owner to configure risk parameters at collateral pool and market wide level
 */
interface IRiskConfigurationModule {
    /**
     * @notice Creates or updates the risk configuration for the given `marketId`
     * @param marketId Id of the market for which the risk parameters are configured
     * @param config The MarketConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     *
     */
    function configureMarketRisk(uint128 marketId, Market.RiskConfiguration memory config) external;

    /**
     * @notice Creates or updates the configuration on the collateral pool level
     * @param collateralPoolId Id of the collateral pool for which the risk parameters are configured
     * @param config It describes the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     *
     */
    function configureCollateralPoolRisk(uint128 collateralPoolId, CollateralPool.RiskConfiguration memory config) external;

    /**
     * @notice Returns detailed information pertaining the specified marketId
     * @param marketId Id that uniquely identifies the market (e.g. aUSDC lend) for which we want to query the risk config
     * @return config The configuration object describing the given marketId
     */
    function getMarketRiskConfiguration(uint128 marketId)
        external
        view
        returns (Market.RiskConfiguration memory config);

    /**
     * @notice Returns detailed information on collateral pool risk configuration
     */
    function getCollateralPoolRiskConfiguration(uint128 collateralPoolId) 
        external 
        view 
        returns 
        (CollateralPool.RiskConfiguration memory config);

    // todo: add natspec
    function configureRiskMatrix(
        uint128 collateralPoolId,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex,
        SD59x18 value
    ) external;

    // todo: add natspec

    function getRiskMatrixParameter(
        uint128 collateralPoolId,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex
    ) external view returns (SD59x18 parameter);
}
