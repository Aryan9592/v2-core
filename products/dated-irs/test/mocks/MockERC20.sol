/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

contract MockERC20 is IERC20 {
    function name() external pure virtual returns (string memory) {
        return "name";
    }

    function symbol() external pure virtual returns (string memory) {
        return "symbol";
    }

    function decimals() external pure virtual returns (uint8) {
        return 18;
    }

    function totalSupply() external pure virtual returns (uint256) {
        return 0;
    }

    function balanceOf(address owner) external pure virtual returns (uint256) {
        return 0;
    }

    function allowance(address owner, address spender) external pure virtual returns (uint256) {
        return 0;
    }

    function transfer(address to, uint256 amount) external pure virtual returns (bool) {
        return false;
    }

    function approve(address spender, uint256 amount) external pure virtual returns (bool) {
        return false;
    }

    function increaseAllowance(address spender, uint256 addedValue) external pure virtual returns (bool) {
        return false;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external pure virtual returns (bool) {
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) external pure virtual returns (bool) {
        return false;
    }
}
