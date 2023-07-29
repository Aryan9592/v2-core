pragma solidity >=0.8.19;

import "./utils/BaseScenario.sol";
import "./utils/TestUtils.sol";

import {CollateralConfiguration} from "@voltz-protocol/core/src/storage/CollateralConfiguration.sol";
import {ProtocolRiskConfiguration} from "@voltz-protocol/core/src/storage/ProtocolRiskConfiguration.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {MarketFeeConfiguration} from "@voltz-protocol/core/src/storage/MarketFeeConfiguration.sol";
import {MarketRiskConfiguration} from "@voltz-protocol/core/src/storage/MarketRiskConfiguration.sol";

import {ProductConfiguration} from "@voltz-protocol/products-dated-irs/src/storage/ProductConfiguration.sol";
import {MarketConfiguration} from "@voltz-protocol/products-dated-irs/src/storage/MarketConfiguration.sol";

import "@voltz-protocol/v2-vamm/utils/vamm-math/TickMath.sol";
import {ExtendedPoolModule} from "@voltz-protocol/v2-vamm/test/PoolModule.t.sol";
import {VammConfiguration, IRateOracle} from "@voltz-protocol/v2-vamm/utils/vamm-math/VammConfiguration.sol";

import {SafeCastI256, SafeCastU256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { ud60x18, div, SD59x18, UD60x18 } from "@prb/math/UD60x18.sol";
import { sd59x18, abs } from "@prb/math/SD59x18.sol";

import "forge-std/console2.sol";

contract MultiMarketsScenarios is TestUtils, BaseScenario {
  using SafeCastI256 for int256;
  using SafeCastU256 for uint256;
  using SafeCastU128 for uint128;

  uint256 internal constant Q96 = 0x1000000000000000000000000;
  uint256 internal constant WAD = 1_000_000_000_000_000_000;

  address internal user1;
  address internal user2;

  uint128 productId;
  uint128 marketId;
  uint32 maturityTimestamp;
  uint32 maturityTimestamp2;
  uint256 imMultiplier = 2;
  uint256 riskParam = 1e17;
  ExtendedPoolModule extendedPoolModule; // used to convert base to liquidity :)

  using SetUtil for SetUtil.Bytes32Set;

  struct TakerExecutedAmounts {
    uint256 depositedAmount;
    int256 executedBaseAmount;
    int256 executedQuoteAmount;
    uint256 fee;
    uint256 im;
    // todo: add highestUnrealizedLoss
      // todo: can we pull more information to play with in tests?
  }

  struct MakerExecutedAmounts {
    int256 baseAmount;
    uint256 depositedAmount;
    int24 tickLower;
    int24 tickUpper;
    uint256 fee;
    uint256 im;
    // todo: add highestUnrealizedLoss
    // todo: can we pull more information to play with in tests?
  }

  function setUp() public {
    super._setUp();
    user1 = vm.addr(1);
    user2 = vm.addr(2);
    marketId = 1;
    // in 30 days pools (time will be advanced by 1 day before creating the pools)
    maturityTimestamp = uint32(block.timestamp) + 86400 + 86400 * 30; 
    maturityTimestamp2 = uint32(block.timestamp) + 86400 + 86400 * 365; // one year pool
    extendedPoolModule = new ExtendedPoolModule();
  }

  function setPool(uint32 _maturityTimestamp) public {
    vm.startPrank(owner);

    VammConfiguration.Immutable memory immutableConfig = VammConfiguration.Immutable({
        maturityTimestamp: _maturityTimestamp,
        _maxLiquidityPerTick: type(uint128).max,
        _tickSpacing: 60,
        marketId: marketId
    });

    VammConfiguration.Mutable memory mutableConfig = VammConfiguration.Mutable({
        priceImpactPhi: ud60x18(0), // 0
        priceImpactBeta: ud60x18(0), // 0
        spread: ud60x18(10e14), // 0.1% 10 bps
        rateOracle: IRateOracle(address(aaveV3RateOracle)),
        minTick: TickMath.DEFAULT_MIN_TICK,
        maxTick: TickMath.DEFAULT_MAX_TICK
    });

    vammProxy.setProductAddress(address(datedIrsProxy));
    vm.warp(block.timestamp + 86400); // advance by 1 days
    uint32[] memory times = new uint32[](2);
    times[0] = uint32(block.timestamp - 86400);
    times[1] = uint32(block.timestamp - 43200);
    int24[] memory observedTicks = new int24[](2);
    observedTicks[0] = -13860;
    observedTicks[1] = -13860;
    vammProxy.createVamm(
      marketId,
      TickMath.getSqrtRatioAtTick(-13860), // price = 4%
      times,
      observedTicks,
      immutableConfig,
      mutableConfig
    );
    vammProxy.increaseObservationCardinalityNext(marketId, _maturityTimestamp, 16);
    vammProxy.setMakerPositionsPerAccountLimit(1);


    vm.stopPrank();
  }

  function setConfigs() public {

    // COLLATERAL & PROTOCOL RISK & MARKET
    {
        vm.startPrank(owner);

        coreProxy.configureCollateral(
        CollateralConfiguration.Data({
                depositingEnabled: true,
                liquidationBooster: 0,
                tokenAddress: address(token),
                cap: 1000000e18,
                oracleNodeId: "0x",
                weight: 1e18,
                autoExchangeReward: 0
            })
        );
        coreProxy.configureProtocolRisk(
        ProtocolRiskConfiguration.Data({
                imMultiplier: UD60x18.wrap(2e18),
                liquidatorRewardParameter: UD60x18.wrap(5e16)
            })
        );

        productId = coreProxy.registerProduct(address(datedIrsProxy), "Dated IRS Product");

        datedIrsProxy.configureMarket(
            MarketConfiguration.Data({
                marketId: marketId,
                quoteToken: address(token)
            })
        );
        datedIrsProxy.setVariableOracle(
            1,
            address(aaveV3RateOracle),
            3600
        );
        datedIrsProxy.configureProduct(
        ProductConfiguration.Data({
                productId: productId,
                coreProxy: address(coreProxy),
                poolAddress: address(vammProxy),
                takerPositionsPerAccountLimit: 3
            })
        );

        coreProxy.configureMarketFee(
        MarketFeeConfiguration.Data({
                productId: productId,
                marketId: marketId,
                feeCollectorAccountId: feeCollectorAccountId,
                atomicMakerFee: UD60x18.wrap(0),
                atomicTakerFee: UD60x18.wrap(2e14) // 2 bps = 0.02% = 0.0002
            })
        );
        coreProxy.configureMarketRisk(
        MarketRiskConfiguration.Data({
                productId: productId, 
                marketId: marketId, 
                riskParameter: UD60x18.wrap(1e17), // 10%
                twapLookbackWindow: 120
            })
        );

        vm.stopPrank();
    }
    
    setPool(maturityTimestamp);
    setPool(maturityTimestamp2);
    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1e18));

    // ACCESS PASS
    addressPassNftInfo.add(keccak256(abi.encodePacked(user1, uint256(1))));
    addressPassNftInfo.add(keccak256(abi.encodePacked(user2, uint256(1))));
    addressPassNftInfo.add(keccak256(abi.encodePacked(vm.addr(3), uint256(1))));
    addressPassNftInfo.add(keccak256(abi.encodePacked(vm.addr(4), uint256(1))));
    addressPassNftInfo.add(keccak256(abi.encodePacked(vm.addr(5), uint256(1))));
    addressPassNftInfo.add(keccak256(abi.encodePacked(vm.addr(6), uint256(1))));

    vm.startPrank(owner);
    accessPassNft.addNewRoot(
      AccessPassNFT.RootInfo({
        merkleRoot: merkle.getRoot(addressPassNftInfo.values()),
        baseMetadataURI: "ipfs://"
      })
    );
    vm.stopPrank();

    vm.warp(block.timestamp + 43200); // advance by 0.5 days
  }

  function newMaker(
    uint128 _marketId,
    uint32 _maturityTimestamp,
    uint128 accountId,
    address user,
    uint256 count,
    uint256 merkleIndex,
    uint256 toDeposit,
    int256 baseAmount,
    int24 tickLower,
    int24 tickUpper
    ) public returns (MakerExecutedAmounts memory){
    vm.startPrank(user);

    token.mint(user, toDeposit);

    token.approve(address(peripheryProxy), toDeposit);

    redeemAccessPass(user, count, merkleIndex);

    // PERIPHERY LP COMMAND
    int128 liquidity = extendedPoolModule.getLiquidityForBase(tickLower, tickUpper, baseAmount);
    console2.log("liquidity", liquidity);
    bytes memory commands = abi.encodePacked(
        bytes1(uint8(Commands.V2_CORE_CREATE_ACCOUNT)),
        bytes1(uint8(Commands.TRANSFER_FROM)),
        bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
        bytes1(uint8(Commands.V2_VAMM_EXCHANGE_LP))
    );
    bytes[] memory inputs = new bytes[](4);
    inputs[0] = abi.encode(accountId);
    inputs[1] = abi.encode(address(token), toDeposit);
    inputs[2] = abi.encode(accountId, address(token), toDeposit);
    inputs[3] = abi.encode(
        accountId,
        _marketId,
        _maturityTimestamp,
        tickLower,
        tickUpper,
        liquidity
    );
    bytes[] memory output = peripheryProxy.execute(commands, inputs, block.timestamp + 1);

    (
      uint256 fee,
      uint256 im
    ) = abi.decode(output[3], (uint256, uint256));

    vm.stopPrank();

    return MakerExecutedAmounts({
      baseAmount: baseAmount,
      depositedAmount: toDeposit,
      tickLower: tickLower,
      tickUpper: tickUpper,
      fee: fee,
      im: im
    });

  }

  function newTaker(
    uint128 _marketId,
    uint32 _maturityTimestamp,
    uint128 accountId,
    address user,
    uint256 count,
    uint256 merkleIndex,
    uint256 toDeposit,
    int256 baseAmount
    ) public returns (TakerExecutedAmounts memory executedAmounts) {
    uint256 margin = toDeposit - 0; // minus liquidation booster

    vm.startPrank(user);

    token.mint(user, toDeposit);

    token.approve(address(peripheryProxy), toDeposit);

    redeemAccessPass(user, count, merkleIndex);

    bytes memory commands = abi.encodePacked(
        bytes1(uint8(Commands.V2_CORE_CREATE_ACCOUNT)),
        bytes1(uint8(Commands.TRANSFER_FROM)),
        bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
        bytes1(uint8(Commands.V2_DATED_IRS_INSTRUMENT_SWAP))
    );
    bytes[] memory inputs = new bytes[](4);
    inputs[0] = abi.encode(accountId);
    inputs[1] = abi.encode(address(token), toDeposit);
    inputs[2] = abi.encode(accountId, address(token), margin);
    inputs[3] = abi.encode(
        accountId,  // accountId
        _marketId,
        _maturityTimestamp,
        baseAmount,
        0 // MIN_SQRT_LIMIT, VT
    );
    bytes[] memory output = peripheryProxy.execute(commands, inputs, block.timestamp + 1);

    // todo: add unrealized loss to exposures
    (
      executedAmounts.executedBaseAmount,
      executedAmounts.executedQuoteAmount,
      executedAmounts.fee, 
      executedAmounts.im,,
    ) = abi.decode(output[3], (int256, int256, uint256, uint256, uint256, int24));

    executedAmounts.depositedAmount = toDeposit;

    vm.stopPrank();

  }

  struct MarginData {
    bool liquidatable;
    uint256 initialMarginRequirement;
    uint256 liquidationMarginRequirement;
    uint256 highestUnrealizedLoss;
  }

  struct UnfilledData {
    uint256 unfilledBaseLong;
    uint256 unfilledQuoteLong;
    uint256 unfilledBaseShort;
    uint256 unfilledQuoteShort;
  }

  function checkImMaker(
    uint128 _marketId,
    uint32 _maturityTimestamp,
    uint128 accountId,
    address user,
    int256 _filledBase,
    MakerExecutedAmounts memory executedAmounts,
    uint256 twap
  ) public returns (MarginData memory m, UnfilledData memory u){

      uint256 currentLiquidityIndex = UD60x18.unwrap(aaveV3RateOracle.getCurrentIndex());

      (
        m.liquidatable,
        m.initialMarginRequirement,
        m.liquidationMarginRequirement,
        m.highestUnrealizedLoss
      ) = coreProxy.isLiquidatable(accountId, address(token));

      console2.log("liquidatable", m.liquidatable);
      console2.log("initialMarginRequirement", m.initialMarginRequirement);
      console2.log("liquidationMarginRequirement", m.liquidationMarginRequirement);
      console2.log("highestUnrealizedLoss",m.highestUnrealizedLoss);

      (u.unfilledBaseLong, u.unfilledBaseShort, u.unfilledQuoteLong, u.unfilledQuoteShort) =
      vammProxy.getAccountUnfilledBaseAndQuote(_marketId, _maturityTimestamp, accountId);

      console2.log("unfilledBaseLong", u.unfilledBaseLong);
      console2.log("unfilledQuoteLong", u.unfilledQuoteLong);
      console2.log("unfilledBaseShort", u.unfilledBaseShort);
      console2.log("unfilledQuoteShort", u.unfilledQuoteShort);

      assertEq(uint256(executedAmounts.baseAmount), u.unfilledBaseLong+u.unfilledBaseShort + 1, "unfilledBase");
      assertEq(m.liquidatable, false, "liquidatable");
      assertGe(m.initialMarginRequirement, m.liquidationMarginRequirement, "lmr");

      // calculate LMRLow
      uint256 baseLower = absUtil(_filledBase - u.unfilledBaseShort.toInt());
      uint256 baseUpper = absUtil(_filledBase + u.unfilledBaseLong.toInt());
      uint256 expectedLmrLower = (riskParam * baseLower) * currentLiquidityIndex * timeFactor(maturityTimestamp) / 1e54;
      uint256 expectedLmrUpper = (riskParam * baseUpper) * currentLiquidityIndex * timeFactor(maturityTimestamp) / 1e54;

      console2.log("baseLower", baseLower);
      console2.log("baseUpper", baseUpper);
      console2.log("expectedLmrLower", expectedLmrLower);
      console2.log("expectedLmrUpper", expectedLmrUpper);

      // calculate unrealized loss low
      uint256 unrealizedLossLower = absOrZero(u.unfilledQuoteShort.toInt() - 
        (baseLower * currentLiquidityIndex * (twap * timeFactor(maturityTimestamp) / 1e18 + 1e18) / 1e36).toInt());
      uint256 unrealizedLossUpper = absOrZero(-u.unfilledQuoteLong.toInt() + 
        (baseUpper * currentLiquidityIndex * (twap * timeFactor(maturityTimestamp) / 1e18 + 1e18) / 1e36).toInt());
      console2.log("unrealizedLossLower", unrealizedLossLower);
      console2.log("unrealizedLossUpper", unrealizedLossUpper);

      // todo: manually calculate liquidation margin requirement for lower and upper scenarios and compare to the above
      uint256 expectedUnrealizedLoss = unrealizedLossUpper;
      uint256 expectedLmr = expectedLmrUpper;
      if (unrealizedLossLower + expectedLmrLower >  unrealizedLossUpper + expectedLmrUpper) {
          expectedUnrealizedLoss = unrealizedLossLower;
          expectedLmr = expectedLmrLower;
      }

      assertEq(expectedUnrealizedLoss, m.highestUnrealizedLoss, "expectedUnrealizedLoss");
      assertAlmostEq(expectedLmr, m.liquidationMarginRequirement, 1e5);
      assertAlmostEq(expectedLmr * imMultiplier, m.initialMarginRequirement, 1e5);
      assertGt(executedAmounts.depositedAmount, expectedLmr * imMultiplier + expectedUnrealizedLoss, "IMR");
      // through unrealized
      // through withdraw
  }

  function checkImTaker(
    uint128 _marketId,
    uint32 _maturityTimestamp,
    uint128 accountId,
    address user,
    TakerExecutedAmounts memory executedAmounts,
    uint256 twap
  ) public returns (MarginData memory m, UnfilledData memory u){

      uint256 currentLiquidityIndex = UD60x18.unwrap(aaveV3RateOracle.getCurrentIndex());

      (
        m.liquidatable,
        m.initialMarginRequirement,
        m.liquidationMarginRequirement,
        m.highestUnrealizedLoss
      ) = coreProxy.isLiquidatable(accountId, address(token));

      console2.log("liquidatable", m.liquidatable);
      console2.log("initialMarginRequirement", m.initialMarginRequirement);
      console2.log("liquidationMarginRequirement", m.liquidationMarginRequirement);
      console2.log("highestUnrealizedLoss",m.highestUnrealizedLoss);

      (u.unfilledBaseLong, u.unfilledBaseShort, u.unfilledQuoteLong, u.unfilledQuoteShort) =
        vammProxy.getAccountUnfilledBaseAndQuote(_marketId, _maturityTimestamp, accountId);

      assertEq(0, u.unfilledBaseLong);
      assertEq(0, u.unfilledQuoteLong);
      assertEq(0, u.unfilledBaseShort);
      assertEq(0, u.unfilledQuoteShort);

      assertEq(m.liquidatable, false, "liquidatable");
      assertGe(m.initialMarginRequirement, m.liquidationMarginRequirement, "lmr");

      // calculate LMR
      uint256 expectedLmr = (riskParam * absUtil(executedAmounts.executedBaseAmount)) * currentLiquidityIndex * timeFactor(maturityTimestamp) / 1e54;
      console2.log("expectedLmr", expectedLmr);

      // calculate unrealized loss low
      uint256 expectedUnrealizedLoss = absOrZero(executedAmounts.executedQuoteAmount + 
        (executedAmounts.executedBaseAmount * currentLiquidityIndex.toInt() * (twap * timeFactor(maturityTimestamp) / 1e18 + 1e18).toInt() / 1e36));

      console2.log("expectedUnrealizedLoss", expectedUnrealizedLoss);
      assertAlmostEq(expectedUnrealizedLoss.toInt(), m.highestUnrealizedLoss.toInt(), 1e5);
      assertAlmostEq(expectedLmr, m.liquidationMarginRequirement, 1e5);
      assertAlmostEq(expectedLmr * imMultiplier, m.initialMarginRequirement, 1e5);
      assertGt(executedAmounts.depositedAmount, expectedLmr * imMultiplier + expectedUnrealizedLoss, "IMR taker");
  }


  function redeemAccessPass(address user, uint256 count, uint256 merkleIndex) public {
    accessPassNft.redeem(
      user,
      count,
      merkle.getProof(addressPassNftInfo.values(), merkleIndex),
      merkle.getRoot(addressPassNftInfo.values())
    );
  }

  ///////// TESTS /////////

  function test_track_margin_one_lp() public {
    /// note same positions taken by different users at 0.5 days interval
    /// change in the liquidity index
    setConfigs();

    TakerExecutedAmounts[] memory takerAmounts = new TakerExecutedAmounts[](3);
    MakerExecutedAmounts[] memory makerAmounts = new MakerExecutedAmounts[](3);

    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1.02e18)); // 2.5 days till end

    // LP - 1st pool
    makerAmounts[0] = newMaker(
        marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        1, // count,
        2, // merkleIndex
        1001e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // check im
    int24 tick = vammProxy.getVammTick(marketId, maturityTimestamp);
    uint256 twap = priceFromTick(tick) / 100;
    assertAlmostEq(4e16, twap.toInt(), 1e15); // 0.1% error
    checkImMaker(
      marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        0,
        makerAmounts[0],
        twap 
    );
  }

  function test_track_margin_one_lp_one_trader() public {
    /// note same positions taken by different users at 0.5 days interval
    /// change in the liquidity index
    setConfigs();

    TakerExecutedAmounts[] memory takerAmounts = new TakerExecutedAmounts[](3);
    MakerExecutedAmounts[] memory makerAmounts = new MakerExecutedAmounts[](3);

    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1.02e18)); // 2.5 days till end

    // LP - 1st pool
    makerAmounts[0] = newMaker(
        marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        1, // count,
        2, // merkleIndex
        1001e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // check im
    int24 tick = vammProxy.getVammTick(marketId, maturityTimestamp);
    uint256 twap = priceFromTick(tick) / 100;
    assertAlmostEq(4e16, twap.toInt(), 1e15); // 0.1% error
    console2.log("CHECK LP ---------");
    (MarginData memory mBefore,) = checkImMaker(
      marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        0,
        makerAmounts[0],
        twap 
    );

    // FT
    takerAmounts[0] = newTaker(
        marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        1, // count,
        3, // merkleIndex
        100e18, // toDeposit
        -500e18 // baseAmount
    );

    int24 tick2 = vammProxy.getVammTick(marketId, maturityTimestamp);
    uint256 twap2 = UD60x18.unwrap(vammProxy.getAdjustedDatedIRSTwap(
      marketId, maturityTimestamp, 
      500e18, 120
    ));
    console2.log("CHECK TAKER ---------");
    checkImTaker(
      marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        takerAmounts[0],
        twap2 
    );

    // CHECK LP's margin data after some liquidity was consumed
    MarginData memory mAfter;
    (
        mAfter.liquidatable,
        mAfter.initialMarginRequirement,
        mAfter.liquidationMarginRequirement,
        mAfter.highestUnrealizedLoss
    ) = coreProxy.isLiquidatable(1, address(token));

    assertEq(mAfter.liquidatable, false);
    assertEq(mAfter.highestUnrealizedLoss, mBefore.highestUnrealizedLoss);
    // tick before was in the middle => modes towards 1 side => LMR is higher
    assertGt(mAfter.liquidationMarginRequirement, mBefore.liquidationMarginRequirement);
  }

  // reason: unrealized loss
  function test_liquidation_lp() public {
    /// note same positions taken by different users at 0.5 days interval
    /// no change in the liquidity index
    setConfigs();

    TakerExecutedAmounts[] memory takerAmounts = new TakerExecutedAmounts[](3);
    MakerExecutedAmounts[] memory makerAmounts = new MakerExecutedAmounts[](3);

    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1e18));

    // LP - 1st pool
    makerAmounts[0] = newMaker(
        marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        1, // count,
        2, // merkleIndex
        500e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // coverup for future liquidation
    // without extra liquidity, LP can't unwind (tries to take VT)
    makerAmounts[1] = newMaker(
        marketId,
        maturityTimestamp,
        3, // accountId
        vm.addr(3), // user
        1, // count,
        4, // merkleIndex
        500e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // check im
    console2.log("CHECK LP ---------");
    (MarginData memory mBefore,) = checkImMaker(
      marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        0,
        makerAmounts[0],
        priceFromTick(-13860) / 100 
    );

    vm.warp(block.timestamp + 86400 * 5); // 5 days past
    // 15.7% apy
    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1.002e18));

    // VT
    takerAmounts[0] = newTaker(
        marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        1, // count,
        3, // merkleIndex
        100e18, // toDeposit
        500e18 // baseAmount
    );

    uint256 twap3 = UD60x18.unwrap(vammProxy.getAdjustedDatedIRSTwap(
      marketId, maturityTimestamp, 
      -500e18, 120
    ));
    console2.log("CHECK TAKER ---------"); 
    checkImTaker(
        marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        takerAmounts[0],
        twap3
    );

    vm.warp(block.timestamp + 86400 * 5); // 5 days past
    // bump the index to make LP liquidatable - LMR
    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(2.8e18));

    // CHECK LP's margin data after some liquidity was consumed
    console2.log("CHECK LP ---------"); 
    MarginData memory mAfterSwap;
    (
        mAfterSwap.liquidatable,
        mAfterSwap.initialMarginRequirement,
        mAfterSwap.liquidationMarginRequirement,
        mAfterSwap.highestUnrealizedLoss
    ) = coreProxy.isLiquidatable(1, address(token));

    // lmr 71.678952195079287421 hloss 449.845037907720900220
    // note lmr grows with liquidityIndex
    // if lmr grows such that the position becomes
    console2.log("mAfterSwap.liquidatable", mAfterSwap.liquidatable);
    console2.log("mAfterSwap.highestUnrealizedLoss", mAfterSwap.highestUnrealizedLoss);
    console2.log("mAfterSwap.liquidationMarginRequirement", mAfterSwap.liquidationMarginRequirement);

    assertEq(mAfterSwap.liquidatable, true);
    assertGt(mAfterSwap.highestUnrealizedLoss, mBefore.highestUnrealizedLoss);
    // tick before was in the middle => modes towards 1 side => LMR is higher
    assertGt(mAfterSwap.liquidationMarginRequirement, mBefore.liquidationMarginRequirement);

    console2.log("-------- LIQUIDATION -------");
    vm.startPrank(vm.addr(4));
    redeemAccessPass(vm.addr(4), 1, 5);
    coreProxy.createAccount(4, vm.addr(4));
    coreProxy.liquidate(1, 4, address(token));
    vm.stopPrank();

    MarginData memory mAfterLiq;
    (
        ,
        mAfterLiq.initialMarginRequirement,
        mAfterLiq.highestUnrealizedLoss,
    ) = coreProxy.isLiquidatable(1, address(token));
    assertLt(mAfterLiq.initialMarginRequirement + mAfterLiq.highestUnrealizedLoss,
      mAfterSwap.initialMarginRequirement + mAfterSwap.highestUnrealizedLoss);
    
    // liq reward sent
    assertEq(coreProxy.getAccountCollateralBalance(1, address(token)), 
      makerAmounts[0].depositedAmount -
      takerAmounts[0].executedBaseAmount.toUint() / 2 * 2.8e18 / 1e18 * timeFactor(maturityTimestamp) / 1e18 * 0.0002e18 / 1e18 -
      coreProxy.getAccountCollateralBalance(4, address(token)), "qt");
  }

  function test_liquidation_trader() public {
    /// note same positions taken by different users at 0.5 days interval
    /// no change in the liquidity index
    setConfigs();

    TakerExecutedAmounts[] memory takerAmounts = new TakerExecutedAmounts[](3);
    MakerExecutedAmounts[] memory makerAmounts = new MakerExecutedAmounts[](3);

    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1e18));

    // LP - 1st pool
    makerAmounts[0] = newMaker(
        marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        1, // count,
        2, // merkleIndex
        500e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // coverup for future liquidation
    // without extra liquidity, LP can't unwind (tries to take VT)
    makerAmounts[1] = newMaker(
        marketId,
        maturityTimestamp,
        3, // accountId
        vm.addr(3), // user
        1, // count,
        4, // merkleIndex
        500e18, // toDeposit
        10000e18, // baseAmount
        -14100, // 4.1%
        -13620 // 3.9%
    );

    // check im
    console2.log("CHECK LP ---------");
    checkImMaker(
      marketId,
        maturityTimestamp,
        1, // accountId
        vm.addr(1), // user
        0,
        makerAmounts[0],
        priceFromTick(-13860) / 100 
    );

    vm.warp(block.timestamp + 86400 * 5); // 5 days past
    // 15.7% apy
    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1.002e18));

    // FT
    takerAmounts[0] = newTaker(
        marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        1, // count,
        3, // merkleIndex
        7e18, // toDeposit
        -50e18 // baseAmount
    );

    uint256 twap3 = UD60x18.unwrap(vammProxy.getAdjustedDatedIRSTwap(
      marketId, maturityTimestamp, 
      50e18, 120
    ));
    console2.log("CHECK TAKER ---------"); 
    (MarginData memory mBefore, )= checkImTaker(
        marketId,
        maturityTimestamp,
        2, // accountId
        vm.addr(2), // user
        takerAmounts[0],
        twap3
    );

    vm.warp(block.timestamp + 86400); // 1 day passes
    // bump the index to make LP liquidatable - LMR
    aaveLendingPool.setReserveNormalizedIncome(IERC20(token), ud60x18(1.135e18));

    // CHECK LP's margin data after some liquidity was consumed
    console2.log("CHECK TRADER ---------"); 
    MarginData memory mAfterVolatility;
    (
        mAfterVolatility.liquidatable,
        mAfterVolatility.initialMarginRequirement,
        mAfterVolatility.liquidationMarginRequirement,
        mAfterVolatility.highestUnrealizedLoss
    ) = coreProxy.isLiquidatable(2, address(token));

    // note lmr grows with liquidityIndex
    // if lmr grows such that the position becomes
    console2.log("mAfterVolatility.liquidatable", mAfterVolatility.liquidatable);
    console2.log("mAfterVolatility.highestUnrealizedLoss", mAfterVolatility.highestUnrealizedLoss);
    console2.log("mAfterVolatility.liquidationMarginRequirement", mAfterVolatility.liquidationMarginRequirement);

    assertEq(mAfterVolatility.liquidatable, true);
    assertGt(mAfterVolatility.highestUnrealizedLoss, mBefore.highestUnrealizedLoss);
    // tick before was in the middle => modes towards 1 side => LMR is higher
    assertGt(mAfterVolatility.liquidationMarginRequirement, mBefore.liquidationMarginRequirement);
    uint256 marginBefore = coreProxy.getAccountCollateralBalance(2, address(token));

    console2.log("-------- LIQUIDATION -------");
    vm.startPrank(vm.addr(4));
    redeemAccessPass(vm.addr(4), 1, 5);
    coreProxy.createAccount(4, vm.addr(4));
    coreProxy.liquidate(2, 4, address(token));
    vm.stopPrank();

    MarginData memory mAfterLiq;
    (
        ,
        mAfterLiq.initialMarginRequirement,,
        mAfterLiq.highestUnrealizedLoss
    ) = coreProxy.isLiquidatable(2, address(token));
    assertLt(mAfterLiq.initialMarginRequirement + mAfterLiq.highestUnrealizedLoss,
      mAfterVolatility.initialMarginRequirement + mAfterVolatility.highestUnrealizedLoss);
    
    // liq reward sent
    console2.log(coreProxy.getAccountCollateralBalance(4, address(token)));
    console2.log((-takerAmounts[0].executedBaseAmount).toUint() * 1.135e18 / 1e18 * timeFactor(maturityTimestamp) / 1e18 * 0.0002e18 / 1e18 );

    assertEq(coreProxy.getAccountCollateralBalance(2, address(token)), 
      marginBefore -
      (-takerAmounts[0].executedBaseAmount).toUint() * 1.135e18 / 1e18 * timeFactor(maturityTimestamp) / 1e18 * 0.0002e18 / 1e18 -
      coreProxy.getAccountCollateralBalance(4, address(token)), "qt");
  }

}