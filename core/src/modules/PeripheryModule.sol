/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Periphery.sol";
import "../interfaces/IPeripheryModule.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for setting the allowed periphery address.
 * @dev See IPeripheryModule.
 */
contract PeripheryModule is IPeripheryModule {

    /**
     * @inheritdoc IPeripheryModule
     */
    function setPeriphery(address peripheryAddress) external override {
        OwnableStorage.onlyOwner();
        
        Periphery.set(Periphery.Data({
            peripheryAddress: peripheryAddress
        }));
    }
}
