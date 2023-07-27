/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import {GlpRateOracle, IRateOracle} from "../../src/oracles/GlpRateOracle.sol";
import {IRewardRouter} from "../../src/interfaces/external/glp/IRewardRouter.sol";
import {IRewardTracker} from "../../src/interfaces/external/glp/IRewardTracker.sol";
import {IGlpManager} from "../../src/interfaces/external/glp/IGlpManager.sol";
import {IVault} from "../../src/interfaces/external/glp/IVault.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {UD60x18, mulDiv, convert as convert_ud} from "@prb/math/UD60x18.sol";

contract GlpRateOracleTest is Test {
  GlpRateOracle glpRateOracle;

  address rewardRouter = vm.addr(100);
  address glpManager = vm.addr(101);
  address rewardTracker = vm.addr(102);
  address vault = vm.addr(103);
  address glp = vm.addr(104);

  address underlying = vm.addr(9);

  function setUp() public virtual {
    // mock calls in constructor
    vm.mockCall(
      rewardRouter,
      abi.encodeCall(IRewardRouter(rewardRouter).glpManager, ()),
      abi.encode(glpManager)
    );
    vm.mockCall(
      rewardRouter,
      abi.encodeCall(IRewardRouter(rewardRouter).feeGlpTracker, ()),
      abi.encode(rewardTracker)
    );
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).vault, ()),
      abi.encode(vault)
    );
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).glp, ()),
      abi.encode(glp)
    );
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).rewardToken, ()),
      abi.encode(underlying)
    );

    // change time
    vm.warp(1690457908);

    // mock calls in _updateState
    mockGlpContracts({
      minEthPrice: 1e30,
      maxEthPrice: 1e30,
      minAum: 1e30,
      maxAum: 1e30,
      supply: 1e18,
      cummulativeReward: 1
    });

    // create glp rate oracle
    glpRateOracle = new GlpRateOracle(
      IRewardRouter(rewardRouter),
      underlying
    );
  }

  function test_State() public {
    assertEq(glpRateOracle.hasState(), true);
    assertEq(glpRateOracle.earliestStateUpdate(), block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    
    vm.expectRevert(IRateOracle.StateUpdateTooEarly.selector);
    glpRateOracle.updateState();

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES() - 1);
    vm.expectRevert(IRateOracle.StateUpdateTooEarly.selector);
    glpRateOracle.updateState();

    vm.warp(block.timestamp + 1);
    glpRateOracle.updateState();
  }

  function test_GlpErrors_InexistentGlpRewardRouter() public {
    vm.expectRevert(GlpRateOracle.InexistentGlpRewardRouter.selector);
    glpRateOracle = new GlpRateOracle(
      IRewardRouter(address(0)),
      underlying
    );
  }

  function test_GlpErrors_NonMatchingUnderlyings() public {
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).rewardToken, ()),
      abi.encode(address(0))
    );
    vm.expectRevert(GlpRateOracle.NonMatchingUnderlyings.selector);
    glpRateOracle = new GlpRateOracle(
      IRewardRouter(rewardRouter),
      underlying
    );
  }

  function test_GlpErrors_FailedGlpPriceFetch1() public {
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    vm.mockCall(
      vault,
      abi.encodeCall(IVault(vault).getMinPrice, (underlying)),
      abi.encode(0)
    );
    vm.mockCall(
      vault,
      abi.encodeCall(IVault(vault).getMaxPrice, (underlying)),
      abi.encode(0)
    );
    vm.expectRevert(GlpRateOracle.FailedGlpPriceFetch.selector);
    glpRateOracle.updateState();
  }

  function test_GlpErrors_FailedGlpPriceFetch2() public {
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).getAum, (false)),
      abi.encode(0)
    );
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).getAum, (true)),
      abi.encode(0)
    );
    vm.expectRevert(GlpRateOracle.FailedGlpPriceFetch.selector);
    glpRateOracle.updateState();
  }

  function test_GlpErrors_UnorderedRewardIndex() public {
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(IRewardTracker(rewardTracker).cumulativeRewardPerToken() - 1)
    );
    vm.expectRevert(GlpRateOracle.UnorderedRewardIndex.selector);
    glpRateOracle.updateState();
  }

  function test_Apy() public {
    mockGlpContracts({
      minEthPrice: 1675040000000000000000000000000000,
      maxEthPrice: 1675040000000000000000000000000000,
      minAum: 500659236326665686228353491203195598169,
      maxAum: 500659236326665256228353491203195598169,
      supply: 522840468811348953941584644,
      cummulativeReward: 193676115672356956833719619
    });
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();

    UD60x18 indexBefore = glpRateOracle.getCurrentIndex();

    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(
        IRewardTracker(rewardTracker).cumulativeRewardPerToken() +
        mulDiv(4803240740740740, glpRateOracle.GLP_PRECISION() * 86400, IERC20(glp).totalSupply())
      )
    );

    vm.warp(block.timestamp + 86400);
    glpRateOracle.updateState();

    UD60x18 indexAfter = glpRateOracle.getCurrentIndex();
    UD60x18 rateOfReturn = indexAfter.sub(indexBefore);
    UD60x18 timeInYears = convert_ud(86400).div(convert_ud(31536000));
    UD60x18 apy = rateOfReturn.div(timeInYears);

    assertEq(apy.unwrap(), 506785185591683805);
  }

  function test_RealisticRates() public {
    mockGlpContracts({
      minEthPrice: 1558e30,
      maxEthPrice: 1590e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 450000000e18,
      cummulativeReward: 30276237000 // last rate = 1e27*(1+prevCum*ethGlp);
    });
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();

    UD60x18 initialIndex = glpRateOracle.getCurrentIndex();

    mockGlpContracts({
      minEthPrice: 1658e30,
      maxEthPrice: 1660e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 400000000e18,
      cummulativeReward: 37276237000
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap() + 11);
    (, uint256 lastEthPriceInGlpGP, uint256 lastCumulativeRewardPerTokenGP, ) = glpRateOracle.state();
    assertEq(lastEthPriceInGlpGP, 1474666666666666666666666666666666);
    assertEq(lastCumulativeRewardPerTokenGP, 37276237000);

    // another update
    initialIndex = glpRateOracle.getCurrentIndex();
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(39276237000)
    );

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap() + 2);
  }

  function test_HighToLowPrices() public {
    mockGlpContracts({
      minEthPrice: 1658e30,
      maxEthPrice: 1660e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 450000000e18, // => old Price = 1659
      cummulativeReward: 30276237000 // last rate = 1e27*(1+prevCum*ethGlp);
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();

    UD60x18 initialIndex = glpRateOracle.getCurrentIndex();

    mockGlpContracts({
      minEthPrice: 16e30,
      maxEthPrice: 17e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 600000000e18,
      cummulativeReward: 37276237000
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap() + 11);
    (, uint256 lastEthPriceInGlpGP, uint256 lastCumulativeRewardPerTokenGP, ) = glpRateOracle.state();
    assertEq(lastEthPriceInGlpGP, 22000000000000000000000000000014);
    assertEq(lastCumulativeRewardPerTokenGP, 37276237000);

    // another update
    initialIndex = glpRateOracle.getCurrentIndex();
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(89276237000)
    );

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap() + 1);
  }

  function test_LowToHighPrices() public {
    mockGlpContracts({
      minEthPrice: 18e30,
      maxEthPrice: 19e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 450000000e18,
      cummulativeReward: 30276237000 // last rate = 1e27*(1+prevCum*ethGlp);
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();

    UD60x18 initialIndex = glpRateOracle.getCurrentIndex();

    mockGlpContracts({
      minEthPrice: 7658e30,
      maxEthPrice: 7660e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 100000000e18,
      cummulativeReward: 37276237000
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap());
    (, uint256 lastEthPriceInGlpGP, uint256 lastCumulativeRewardPerTokenGP, ) = glpRateOracle.state();
    assertEq(lastEthPriceInGlpGP, 1702e30);
    assertEq(lastCumulativeRewardPerTokenGP, 37276237000);

    // another update
    initialIndex = glpRateOracle.getCurrentIndex();
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(37276238000)
    );

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap());
  }

  function test_NoChangeInReward() public {
    mockGlpContracts({
      minEthPrice: 1558e30,
      maxEthPrice: 1590e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 450000000e18,
      cummulativeReward: 30276237000 // last rate = 1e27*(1+prevCum*ethGlp);
    });
    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();

    UD60x18 initialIndex = glpRateOracle.getCurrentIndex();

    mockGlpContracts({
      minEthPrice: 1658e30,
      maxEthPrice: 1660e30,
      minAum: 400000000e30,
      maxAum: 500000000e30,
      supply: 400000000e18,
      cummulativeReward: 30276237000
    });

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap());
    (, uint256 lastEthPriceInGlpGP, uint256 lastCumulativeRewardPerTokenGP, ) = glpRateOracle.state();
    assertEq(lastEthPriceInGlpGP, 1474666666666666666666666666666666);
    assertEq(lastCumulativeRewardPerTokenGP, 30276237000);

    // another update
    initialIndex = glpRateOracle.getCurrentIndex();
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(30276238000)
    );

    vm.warp(block.timestamp + glpRateOracle.MIN_SECONDS_BETWEEN_STATE_UPDATES());
    glpRateOracle.updateState();
  
    assertEq(glpRateOracle.getCurrentIndex().unwrap(), initialIndex.unwrap() );
  }

  function mockGlpContracts(
    uint256 minEthPrice,
    uint256 maxEthPrice,
    uint256 minAum,
    uint256 maxAum,
    uint256 supply,
    uint cummulativeReward
  ) internal {
    vm.mockCall(
      vault,
      abi.encodeCall(IVault(vault).getMinPrice, (underlying)),
      abi.encode(minEthPrice)
    );
    vm.mockCall(
      vault,
      abi.encodeCall(IVault(vault).getMaxPrice, (underlying)),
      abi.encode(maxEthPrice)
    );
    vm.mockCall(
      glp,
      abi.encodeCall(IERC20(glp).totalSupply, ()),
      abi.encode(supply)
    );
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).getAum, (false)),
      abi.encode(minAum)
    );
    vm.mockCall(
      glpManager,
      abi.encodeCall(IGlpManager(glpManager).getAum, (true)),
      abi.encode(maxAum)
    );
    vm.mockCall(
      rewardTracker,
      abi.encodeCall(IRewardTracker(rewardTracker).cumulativeRewardPerToken, ()),
      abi.encode(cummulativeReward)
    );
  }
}