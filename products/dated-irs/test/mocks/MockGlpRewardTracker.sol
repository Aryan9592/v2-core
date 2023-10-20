/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { IRewardTracker } from "../../src/interfaces/external/glp/IRewardTracker.sol";
import { UD60x18, unwrap } from "@prb/math/UD60x18.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

contract MockGlpRewardTracker is IRewardTracker {
    address public token;
    UD60x18 public apy;
    uint32 public startTime;

    constructor(address _token) {
        token = _token;
    }

    function setStartTime(uint32 start) public {
        startTime = start;
    }

    function setAPY(UD60x18 _apy) external {
        apy = _apy;
    }

    function cumulativeRewardPerToken() external view returns (uint256) {
        return unwrap(apy.mul(Time.timeDeltaAnnualized(startTime, Time.blockTimestampTruncated())));
    }

    function rewardToken() external view returns (address) {
        return token;
    }
}
