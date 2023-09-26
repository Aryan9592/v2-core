pragma solidity >=0.8.19;

import {CollateralConfiguration} from "@voltz-protocol/core/src/storage/CollateralConfiguration.sol";

import {SafeCastI256, SafeCastU256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {ScenarioSetup} from "./utils/ScenarioSetup.sol";
import {AssertionHelpers} from "./utils/AssertionHelpers.sol";
import {Constants} from "./utils/Constants.sol";
import {PoolConfiguration} from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";
import {Market} from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";
import {IAccountModule} from "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IRateOracle} from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import {VammConfiguration} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammConfiguration.sol";
import {DatedIrsVamm} from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";
import {DatedIrsProxy} from "../../src/proxies/DatedIrs.sol";
import {TickMath} from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {Actions} from "./utils/Actions.sol";
import {Checks} from "./utils/Checks.sol";
import {VammProxy} from "../../src/proxies/Vamm.sol";

import { ud60x18, div, SD59x18, UD60x18 } from "@prb/math/UD60x18.sol";

contract Scenario1 is ScenarioSetup, AssertionHelpers, Actions, Checks {
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    address internal user1;
    address internal user2;

    uint128 productId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int24 initTick;

    function getDatedIrsProxy() internal view override returns (DatedIrsProxy) {
        return datedIrsProxy;
    }

    function getCoreProxyAddress() internal view override returns (address) {
        return mockCoreProxy;
    }

    function getVammProxy() internal view override returns (VammProxy) {
        return vammProxy;
    }
    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view override returns(uint32) {
        return 7 * 86400;
    }

    function setUp() public {
        super.datedIrsSetup();
        user1 = vm.addr(1);
        user2 = vm.addr(2);
        marketId = 1;
        maturityTimestamp = uint32(block.timestamp) + 365 * 86400; // in 1 year
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
                markPriceBand: ud60x18(0.01e18), // 10
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

        // ensure the current time > 7 days
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86400 * 8);
        times[1] = uint32(block.timestamp - 86400 * 4);
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

        // FEATURE FLAGS
        datedIrsProxy.addToFeatureFlagAllowlist(
            keccak256(abi.encode(Constants._MARKET_ENABLED_FEATURE_FLAG, marketId)), mockCoreProxy
        );
        vammProxy.addToFeatureFlagAllowlist(Constants._PAUSER_FEATURE_FLAG, address(datedIrsProxy));


        vm.stopPrank();

        aaveLendingPool.setReserveNormalizedIncome(IERC20(mockToken), ud60x18(1e18));
    }

    function test_MINT() public {
        setConfigs();

        // mocks
        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(18)
        );

        // action 
        executeDatedIrsMakerOrder({
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            accountId: 1,
            baseAmount: 10e16,
            tickLower: -13920,
            tickUpper: -13800
        }); 

        checkUnfilledBalances({
            poolAddress: address(vammProxy),
            positionInfo: 
                PositionInfo({accountId: 1, marketId: marketId, maturityTimestamp: maturityTimestamp}),
            expectedUnfilledBaseLong: 49925003805991531, 
            expectedUnfilledBaseShort: 50074996194008468, 
            expectedUnfilledQuoteLong: 250152161433399791, 
            expectedUnfilledQuoteShort: 249702402412509544
        });


    }

    function test_MINT_VT() public {
        test_MINT();

        vm.mockCall(
            mockToken,
            abi.encodeWithSelector(IERC20.decimals.selector),
            abi.encode(18)
        );

        // action 
        (int256 executedBase, int256 executedQuote, int256 annualizedNotional) = 
            executeDatedIrsTakerOrder_noPriceLimit({
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                accountId: 2,
                baseAmount: 10e15
            }); 

        checkUnfilledBalances({
            poolAddress: address(vammProxy),
            positionInfo: PositionInfo({accountId: 2, marketId: marketId, maturityTimestamp: maturityTimestamp}),
            expectedUnfilledBaseLong: 0,
            expectedUnfilledBaseShort: 0,
            expectedUnfilledQuoteLong: 0,
            expectedUnfilledQuoteShort: 0
    });
    }
}