/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import "../../src/interfaces/external/IAaveV3LendingPool.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { UD60x18, ud, unwrap, UNIT } from "@prb/math/UD60x18.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

// import "forge-std/console2.sol";

/// @notice This Mock Aave pool can be used in 3 ways
/// - change the rate to a fixed value (`setReserveNormalizedIncome`)
/// - configure the rate to alter over time (`setFactorPerSecondInRay`) for more dynamic testing
contract MockConstantAaveLendingPool is IAaveV3LendingPool {
    using { unwrap } for UD60x18;

    UD60x18 public apy;
    uint32 public startTime;

    function getReserveNormalizedVariableDebt(address _underlyingAsset) public view override returns (uint256) {
        return 0;
    }

    function getReserveNormalizedIncome(address _underlyingAsset) public view override returns (uint256) {
        UD60x18 currentIndex = UNIT.add(apy.mul(Time.timeDeltaAnnualized(startTime, Time.blockTimestampTruncated())));
        // Convert from UD60x18 to Aave's "Ray" (decmimal scaled by 10^27) to confrom to Aave interface
        return currentIndex.unwrap() * 1e9;
    }

    function setAPY(UD60x18 constantApy) public {
        apy = constantApy;
    }

    function setStartTime(uint32 start) public {
        startTime = start;
    }
}
