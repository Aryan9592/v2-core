pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import {FullMath} from "@voltz-protocol/v2-vamm/src/libraries/math/FullMath.sol";
import {FixedPoint96} from "@voltz-protocol/v2-vamm/src/libraries/math/FixedPoint96.sol";

contract AssertionHelpers is Test {

    function assertAlmostEq(int256 a, int256 b, uint256 eps) public {
        assertGe(a, b - int256(eps));
        assertLe(a, b + int256(eps));
    }

    function assertAlmostEq(int256 a, int256 b, uint256 eps, string memory message) public {
        assertGe(a, b - int256(eps), string.concat(message,"_Ge"));
        assertLe(a, b + int256(eps), string.concat(message,"_Le"));
    }

    function absUtil(int256 a) public pure returns (uint256){
        return a > 0 ? uint256(a) : uint256(-a);
    }

    function absOrZero(int256 a) public pure returns (uint256){
        return a < 0 ? uint256(-a) : 0;
    }
}