/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { IGlpManager } from "../../src/interfaces/external/glp/IGlpManager.sol";
import { IVault } from "../../src/interfaces/external/glp/IVault.sol";
import { MockERC20 } from "./MockERC20.sol";

contract MockGlpManager is IGlpManager {
    IVault public vaultContract;
    address public glpAddress;

    constructor(IVault _vault) {
        vaultContract = _vault;
        glpAddress = address(new MockGlp());
    }

    function getAum(bool maximise) external pure override returns (uint256) {
        return 1;
    }

    function vault() external view override returns (IVault) {
        return vaultContract;
    }

    function glp() external view override returns (address) {
        return glpAddress;
    }
}

contract MockGlp is MockERC20 {
    function totalSupply() external pure override returns (uint256) {
        return 1;
    }
}
