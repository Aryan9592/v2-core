/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import "../interfaces/IInsuranceFundConfigurationModule.sol";
import "../storage/Market.sol";

contract InsuranceFundConfigurationModule is IInsuranceFundConfigurationModule {
    using CollateralPool for CollateralPool.Data;
    using Market for Market.Data;

    // consider introducing an insurance fund config module?
    /**
     * @inheritdoc IInsuranceFundConfigurationModule
     */
    function configureCollateralPoolInsuranceFund(
        uint128 collateralPoolId,
        CollateralPool.InsuranceFundConfig memory config
    ) external override {
        CollateralPool.Data storage collateralPool = CollateralPool.exists(collateralPoolId);
        collateralPool.onlyOwner();
        collateralPool.setInsuranceFundConfig(config);
    }

    /**
     * @inheritdoc IInsuranceFundConfigurationModule
     */
    function getCollateralPoolInsuranceFundConfiguration(uint128 collateralPoolId)
        external
        view
        override
        returns (CollateralPool.InsuranceFundConfig memory config)
    {
        return CollateralPool.exists(collateralPoolId).insuranceFundConfig;
    }
}
