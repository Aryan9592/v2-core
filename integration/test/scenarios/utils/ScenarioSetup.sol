pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import { DatedIrsRouter, DatedIrsProxy } from "../../../src/proxies/DatedIrs.sol";
import { VammRouter, VammProxy } from "../../../src/proxies/Vamm.sol";

import { AaveV3RateOracle } from "@voltz-protocol/products-dated-irs/src/oracles/AaveV3RateOracle.sol";
import { GlpRateOracle } from "@voltz-protocol/products-dated-irs/src/oracles/GlpRateOracle.sol";
import { MockConstantAaveLendingPool } from
    "@voltz-protocol/products-dated-irs/test/mocks/MockConstantAaveLendingPool.sol";
import { MarketManagerConfiguration } from
    "@voltz-protocol/products-dated-irs/src/storage/MarketManagerConfiguration.sol";
import { MockGlpRewardRouter } from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpRewardRouter.sol";
import { MockGlpVault } from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpVault.sol";
import { MockGlpManager } from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpManager.sol";
import { MockGlpRewardTracker } from "@voltz-protocol/products-dated-irs/test/mocks/MockGlpRewardTracker.sol";

import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

contract ScenarioSetup is Test {
    DatedIrsProxy public datedIrsProxy;
    VammProxy public vammProxy;
    address public mockCoreProxy;

    address public mockUsdc;
    address public mockGlpToken;

    MockConstantAaveLendingPool public aaveLendingPool;
    AaveV3RateOracle public aaveV3RateOracle;
    GlpRateOracle public glpRateOracle;
    MockGlpRewardRouter public mockGlpRewardRouter;

    address public owner;

    function datedIrsSetup() public {
        vm.warp(86_400 * 365); // time has to be > lookbackwindow for twap to avoid underflow

        owner = vm.addr(55_555);

        vm.startPrank(owner);

        DatedIrsRouter datedIrsRouter = new DatedIrsRouter();
        datedIrsProxy = new DatedIrsProxy(address(datedIrsRouter), owner);

        VammRouter vammRouter = new VammRouter();
        vammProxy = new VammProxy(address(vammRouter), owner);

        mockCoreProxy = address(827_448);
        datedIrsProxy.configureMarketManager(MarketManagerConfiguration.Data({ coreProxy: mockCoreProxy }));

        mockUsdc = address(6_447_488);

        aaveLendingPool = new MockConstantAaveLendingPool();
        aaveV3RateOracle = new AaveV3RateOracle(aaveLendingPool, mockUsdc);

        MockGlpVault vault = new MockGlpVault();
        MockGlpManager glpManager = new MockGlpManager(vault);
        mockGlpToken = glpManager.glpAddress();
        MockGlpRewardTracker rewardTracker = new MockGlpRewardTracker(mockGlpToken);
        mockGlpRewardRouter = new MockGlpRewardRouter(address(rewardTracker), address(glpManager));
        glpRateOracle = new GlpRateOracle(mockGlpRewardRouter, mockGlpToken);

        vm.stopPrank();
    }
}
