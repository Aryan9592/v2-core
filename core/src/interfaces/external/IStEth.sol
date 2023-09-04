/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

/// @title Interface of stEth
interface IStEth is IERC20 {
    function getTotalShares() external view returns (uint256);
}
