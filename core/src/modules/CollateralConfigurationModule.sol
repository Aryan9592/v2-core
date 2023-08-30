/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ICollateralConfigurationModule} from "../interfaces/ICollateralConfigurationModule.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {CollateralConfiguration} from "../storage/CollateralConfiguration.sol";
import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring system wide collateral.
 * @dev See ICollateralConfigurationModule.
 */
contract CollateralConfigurationModule is ICollateralConfigurationModule {
    using SetUtil for SetUtil.AddressSet;
    using CollateralConfiguration for CollateralConfiguration.Data;

    // /**
    //  * @inheritdoc ICollateralConfigurationModule
    //  */
    // function configureCollateral(address tokenAddress, CollateralConfiguration.Config memory config) external override {
    //     OwnableStorage.onlyOwner();
    //     CollateralConfiguration.set(tokenAddress, config);
    // }

    // /**
    //  * @inheritdoc ICollateralConfigurationModule
    //  */
    // function getCollateralConfigurations(bool hideDisabled)
    //     external
    //     view
    //     override
    //     returns (CollateralConfiguration.Data[] memory)
    // {
    //     SetUtil.AddressSet storage collateralTypes = CollateralConfiguration.loadAvailableCollaterals();
    //     uint256 numCollaterals = collateralTypes.length();

    //     uint256 returningConfig = 0;
    //     for (uint256 i = 1; i <= numCollaterals; i++) {
    //         address collateralType = collateralTypes.valueAt(i);
    //         CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralType);

    //         if (!hideDisabled || collateral.config.depositingEnabled) {
    //             returningConfig++;
    //         }
    //     }

    //     CollateralConfiguration.Data[] memory filteredCollaterals = new CollateralConfiguration.Data[](returningConfig);

    //     returningConfig = 0;
    //     for (uint256 i = 1; i <= numCollaterals; i++) {
    //         address collateralType = collateralTypes.valueAt(i);
    //         CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralType);

    //         if (!hideDisabled || collateral.config.depositingEnabled) {
    //             filteredCollaterals[returningConfig++] = collateral;
    //         }
    //     }

    //     return filteredCollaterals;
    // }

    // /**
    //  * @inheritdoc ICollateralConfigurationModule
    //  */
    // function getCollateralConfiguration(address collateralType)
    //     external
    //     view
    //     override
    //     returns (CollateralConfiguration.Data memory)
    // {
    //     return CollateralConfiguration.exists(collateralType);
    // }
}
