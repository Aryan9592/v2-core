/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import {MockXRateOracle} from "../../src/mocks/MockXRateOracle.sol";
import { UD60x18, unwrap } from "@prb/math/UD60x18.sol";

contract MockXRateOracleTest is Test {
  using { unwrap } for UD60x18;

  MockXRateOracle mockXRateOracle;
  uint256 xChainId = 123456;
  address xRateOracleAddress = vm.addr(111222);
  address operator = vm.addr(333444);

  function setUp() public {
    mockXRateOracle = new MockXRateOracle(xChainId, xRateOracleAddress, operator);
  }

  function test_noMock() public {
    assertEq(mockXRateOracle.getCurrentIndex().unwrap(), 0);
  }

  function test_getters() public {
    assertEq(mockXRateOracle.xChainId(), xChainId);
    assertEq(mockXRateOracle.xRateOracleAddress(), xRateOracleAddress);
    assertEq(mockXRateOracle.operator(), operator);
  }

  function test_mockOperator() public {
    vm.prank(operator);
    mockXRateOracle.mockIndex(UD60x18.wrap(999));
    assertEq(mockXRateOracle.getCurrentIndex().unwrap(), 999);
  }

  function test_mockNoOperator() public {
    vm.expectRevert(bytes("OO"));
    mockXRateOracle.mockIndex(UD60x18.wrap(999));
  }
}
