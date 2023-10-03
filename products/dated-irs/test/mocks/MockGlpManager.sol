/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {IGlpManager} from "../../src/interfaces/external/glp/IGlpManager.sol";
import {IVault} from "../../src/interfaces/external/glp/IVault.sol";

contract MockGlpManager is IGlpManager {

    IVault public vaultContract;

    constructor(IVault _vault) {
        vaultContract = _vault;
    }

    function getAum(bool maximise) external pure override returns (uint256) {
        return 0;
    }

    function vault() external view override returns (IVault) {
        return vaultContract;
    }

    function glp() external pure override returns (address) {
        return address(3982843);
    }
}