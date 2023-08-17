/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Market.sol";

/**
 * @title Module for configuring (protocol and) market wide risk parameters
 * @notice Allows the owner to configure risk parameters at (protocol and) market wide level
 */
interface IFeeConfigurationModule {
    /**
     * @notice Creates or updates the protocol fee configuration for the given `marketId`
     * @param config The MarketFeeConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the protocol.
     */
    function configureProtocolMarketFee(uint128 marketId, Market.FeeConfiguration memory config) external;

    /**
     * @notice Creates or updates the collateral pool fee configuration for the given `marketId`
     * @param config The MarketFeeConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     */
    function configureCollateralPoolMarketFee(uint128 marketId, Market.FeeConfiguration memory config) external;

    /**
     * @notice Creates or updates the collateral pool insurance fund configuration for the given id
     * @param config The InsuranceFundConfig object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     */
    function configureCollateralPoolInsuranceFund(
        uint128 collateralPoolId,
        CollateralPool.InsuranceFundConfig memory config
    ) external;

    /**
     * @notice Returns protocol fee configuration for the given `marketId`
     * @param marketId Id that uniquely identifies the market (e.g. aUSDC lend) for which we want to query the risk config
     * @return config The fee configuration object describing the given marketId
     */
    function getProtocolMarketFeeConfiguration(uint128 marketId)
        external
        view
        returns (Market.FeeConfiguration memory config);

    /**
     * @notice Returns collateral pool fee configuration for the given `marketId`
     * @param marketId Id that uniquely identifies the market (e.g. aUSDC lend) for which we want to query the risk config
     * @return config The fee configuration object describing the given marketId
     */
    function getCollateralPoolMarketFeeConfiguration(uint128 marketId)
        external
        view
        returns (Market.FeeConfiguration memory config);


    /**
     * @notice Returns collateral pool insurance fund configuration for the given id
     * @param collateralPoolId Id that uniquely identifies the collateral pool
     * @return config The insurance fund configuration of that collateral pool
     */
    function getCollateralPoolInsuranceFundConfiguration(uint128 collateralPoolId)
        external
        view
        returns (CollateralPool.InsuranceFundConfig memory config);
}
