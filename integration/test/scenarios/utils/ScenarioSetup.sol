pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {DatedIrsRouter, DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";
import {VammRouter, VammProxy} from "../../../src/proxies/Vamm.sol";

import {AaveV3RateOracle} from "@voltz-protocol/products-dated-irs/src/oracles/AaveV3RateOracle.sol";
import {GlpRateOracle} from "@voltz-protocol/products-dated-irs/src/oracles/GlpRateOracle.sol";
import {MockConstantAaveLendingPool} from "@voltz-protocol/products-dated-irs/test/mocks/MockConstantAaveLendingPool.sol";
import {MarketManagerConfiguration} from "@voltz-protocol/products-dated-irs/src/storage/MarketManagerConfiguration.sol";
import {MockGlpRewardRouter} from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpRewardRouter.sol";
import {MockGlpVault} from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpVault.sol";
import {MockGlpManager} from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpManager.sol";
import {MockGlpRewardTracker} from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpRewardTracker.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {Time} from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import { ud60x18, UD60x18, unwrap, UNIT } from "@prb/math/UD60x18.sol";

contract ScenarioSetup is Test {
  DatedIrsProxy datedIrsProxy;
  VammProxy vammProxy;
  address mockCoreProxy;

  address mockToken;

  MockConstantAaveLendingPool aaveLendingPool;
  AaveV3RateOracle aaveV3RateOracle;
  GlpRateOracle glpRateOracle;
  MockGlpRewardRouter mockGlpRewardRouter;

  address owner;

  function datedIrsSetup() public {
    vm.warp(86400 * 365); // time has to be > lookbackwindow for twap to avoid underflow

    owner = vm.addr(55555);

    vm.startPrank(owner);

    DatedIrsRouter datedIrsRouter = new DatedIrsRouter();
    datedIrsProxy = new DatedIrsProxy(address(datedIrsRouter), owner);
    
    VammRouter vammRouter = new VammRouter();
    vammProxy = new VammProxy(address(vammRouter), owner);

    mockCoreProxy = address(827448);
    datedIrsProxy.configureMarketManager(MarketManagerConfiguration.Data({
      coreProxy: mockCoreProxy
    }));

    mockToken = address(6447488);

    aaveLendingPool = new MockConstantAaveLendingPool();
    aaveV3RateOracle = new AaveV3RateOracle(aaveLendingPool, mockToken);
    
    MockGlpRewardTracker rewardTracker = new MockGlpRewardTracker(mockToken);
    MockGlpVault vault = new MockGlpVault();
    MockGlpManager glpManager = new MockGlpManager(vault);
    mockGlpRewardRouter = 
      new MockGlpRewardRouter(address(rewardTracker), address(glpManager));
    glpRateOracle = new GlpRateOracle(mockGlpRewardRouter, mockToken);

    vm.stopPrank();
  }
}