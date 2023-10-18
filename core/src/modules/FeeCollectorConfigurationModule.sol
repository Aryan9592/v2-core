/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {FeeCollectorConfiguration} from "../storage/FeeCollectorConfiguration.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import {IFeeCollectorConfigurationModule} from "../interfaces/IFeeCollectorConfigurationModule.sol";

contract FeeCollectorConfigurationModule is IFeeCollectorConfigurationModule {


    /**
     * @inheritdoc IFeeCollectorConfigurationModule
     */
    function setFeeCollectorAccountId(uint128 feeCollectorAccountId) external {
        OwnableStorage.onlyOwner();
        FeeCollectorConfiguration.setFeeCollectorAccountId(feeCollectorAccountId);
    }

    /**
     * @inheritdoc IFeeCollectorConfigurationModule
     */
    function getFeeCollectorAccountId() external view returns (uint128 feeCollectorAccountId) {
        FeeCollectorConfiguration.Data storage feeCollectorConfig =  FeeCollectorConfiguration.exists();
        return feeCollectorConfig.feeCollectorAccountId;
    }

}