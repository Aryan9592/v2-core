pragma solidity >=0.8.19;

import {CollateralConfiguration} from "@voltz-protocol/core/src/storage/CollateralConfiguration.sol";

import {SafeCastI256, SafeCastU256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {ScenarioSetup} from "./utils/ScenarioSetup.sol";
import {AssertionHelpers} from "./utils/AssertionHelpers.sol";
import {Constants} from "./utils/Constants.sol";
import {PoolConfiguration} from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import {Market} from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";
import {IRateOracle} from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import {VammConfiguration} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammConfiguration.sol";
import {DatedIrsVamm} from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { IERC20 } from "oz/interfaces/IERC20.sol";

import { ud60x18, div, SD59x18, UD60x18 } from "@prb/math/UD60x18.sol";

contract AtomicScenarios is ScenarioSetup, AssertionHelpers {
  using SafeCastI256 for int256;
  using SafeCastU256 for uint256;
  using SafeCastU128 for uint128;

  address internal user1;
  address internal user2;

  uint128 productId;
  uint128 marketId;
  uint32 maturityTimestamp;
  int24 initTick;

  using SetUtil for SetUtil.Bytes32Set;

  function setUp() public {
    super.datedIrsSetup();
    user1 = vm.addr(1);
    user2 = vm.addr(2);
    marketId = 1;
    maturityTimestamp = uint32(block.timestamp) + 365 * 86400; // in 4 days
    initTick = -13860; // 4%
  }

  function setConfigs() public {
    vm.startPrank(owner);

    //////// MARKET MANAGER CONFIGURATION ////////

    datedIrsProxy.createMarket({
        marketId: marketId,
        quoteToken: address(mockToken),
        marketType: "compounding"
    });
    datedIrsProxy.setMarketConfiguration(
        marketId,
        Market.MarketConfiguration({
            poolAddress: address(vammProxy),
            twapLookbackWindow: 7 * 86400, // 7 days
            markPriceBand: ud60x18(1e17), // 10%
            takerPositionsPerAccountLimit: 100,
            positionSizeUpperLimit: 1e27, // 1B
            positionSizeLowerLimit: 0,
            openInterestUpperLimit: 1e27 // 1B
        })
    );
    datedIrsProxy.setRateOracleConfiguration(
        marketId,
        Market.RateOracleConfiguration({
            oracleAddress: address(aaveV3RateOracle),
            maturityIndexCachingWindowInSeconds: 1e27 // 1B
        })
    );

    //////// VAMM CONFIGURATION ////////

    vammProxy.setPoolConfiguration(PoolConfiguration.Data({
        marketManagerAddress: address(datedIrsProxy),
        makerPositionsPerAccountLimit: 1e27 // 1B
    }));

    DatedIrsVamm.Immutable memory immutableConfig = DatedIrsVamm.Immutable({
        maturityTimestamp: maturityTimestamp,
        maxLiquidityPerTick: type(uint128).max,
        tickSpacing: 60,
        marketId: marketId
    });

    DatedIrsVamm.Mutable memory mutableConfig = DatedIrsVamm.Mutable({
        priceImpactPhi: ud60x18(1e18), // 1
        spread: ud60x18(0), // 0%
        minSecondsBetweenOracleObservations: 10,
        minTickAllowed: TickMath.DEFAULT_MIN_TICK,
        maxTickAllowed: TickMath.DEFAULT_MAX_TICK
    });

    // ensure the current time > 1st day
    uint32[] memory times = new uint32[](2);
    times[0] = uint32(block.timestamp - 86400);
    times[1] = uint32(block.timestamp - 43200);
    int24[] memory observedTicks = new int24[](2);
    observedTicks[0] = -13860;
    observedTicks[1] = -13860;
    vammProxy.createVamm({
        sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTick),
        times: times,
        observedTicks: observedTicks,
        config: immutableConfig,
        mutableConfig: mutableConfig
    });
    vammProxy.increaseObservationCardinalityNext(marketId, maturityTimestamp, 16);

    vm.stopPrank();

    aaveLendingPool.setReserveNormalizedIncome(IERC20(mockToken), ud60x18(1e18));
  }
}