pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {DatedIrsRouter, DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";
import {VammRouter, VammProxy} from "../../../src/proxies/Vamm.sol";

import {AaveV3RateOracle} from "@voltz-protocol/products-dated-irs/src/oracles/AaveV3RateOracle.sol";
import {MockAaveLendingPool} from "@voltz-protocol/products-dated-irs/test/mocks/MockAaveLendingPool.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract ScenarioSetup is Test {
  DatedIrsProxy datedIrsProxy;
  VammProxy vammProxy;
  address mockCorePoxy;

  address mockToken;

  MockAaveLendingPool aaveLendingPool;
  AaveV3RateOracle aaveV3RateOracle;

  address owner;

  function datedIrsSetup() public {
    vm.warp(1687525420); // time has to be > lookbackwindow for twap to avoid underflow

    owner = vm.addr(55555);

    vm.startPrank(owner);

    DatedIrsRouter datedIrsRouter = new DatedIrsRouter();
    datedIrsProxy = new DatedIrsProxy(address(datedIrsRouter), owner);
    
    VammRouter vammRouter = new VammRouter();
    vammProxy = new VammProxy(address(vammRouter), owner);

    mockCorePoxy = address(65458);
    mockToken = address(6447488);

    aaveLendingPool = new MockAaveLendingPool();
    aaveV3RateOracle = new AaveV3RateOracle(aaveLendingPool, mockToken);

    vm.stopPrank();
  }
}