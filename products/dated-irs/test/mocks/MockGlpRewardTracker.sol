/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {IRewardTracker} from "../../src/interfaces/external/glp/IRewardTracker.sol";

contract MockGlpRewardTracker is IRewardTracker {
    
    address public token;

    constructor(address _token) {
        token = _token;
    }

    function cumulativeRewardPerToken() external pure returns (uint256) {
        return 0;
    }
    function rewardToken() external view returns (address) {
        return token;
    }
}