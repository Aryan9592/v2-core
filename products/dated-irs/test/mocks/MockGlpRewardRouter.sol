/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";
import {IRewardRouter} from "../../src/interfaces/external/glp/IRewardRouter.sol";
import {MockGlpRewardTracker} from "./MockGlpRewardTracker.sol";

contract MockGlpRewardRouter is IRewardRouter {
    address public rewardTracker;
    address public manager;

    constructor(address _rewardTracker, address _manager) {
        rewardTracker = _rewardTracker;
        manager = _manager;
    }
    
    function feeGlpTracker() external view override returns (address) {
        return rewardTracker;
    }

    function glpManager() external view override returns (address) {
        return manager;
    }

    function setStartTime(uint32 start) public {
        MockGlpRewardTracker(rewardTracker).setStartTime(start);
    }

    function setAPY(UD60x18 apy) external {
        MockGlpRewardTracker(rewardTracker).setAPY(apy);
    }
}