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
interface IInsuranceFundConfigurationModule {

    /**
     * @notice Creates or updates the collateral pool insurance fund configuration for the given id
     * @param config The InsuranceFundConfig object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the collateral pool.
     * - the given account must already exist
     */
    function configureCollateralPoolInsuranceFund(
        uint128 collateralPoolId,
        CollateralPool.InsuranceFundConfig memory config
    ) external;


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
