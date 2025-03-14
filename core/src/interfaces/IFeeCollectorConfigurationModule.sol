/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {FeeCollectorConfiguration} from "../storage/FeeCollectorConfiguration.sol";

interface IFeeCollectorConfigurationModule {

    // todo: add natspec
    function setFeeCollectorAccountId(uint128 feeCollectorAccountId) external;

    // todo: add natspec
    function getFeeCollectorAccountId() external view returns (uint128 feeCollectorAccountId);

}