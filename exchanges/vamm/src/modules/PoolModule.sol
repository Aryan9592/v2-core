// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { IPoolModule } from "../interfaces/IPoolModule.sol";

import { DatedIrsVamm } from "../storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "../storage/PoolConfiguration.sol";
import { LPPosition } from "../storage/LPPosition.sol";

import { Twap } from "../libraries/vamm-utils/Twap.sol";
import { VammTicks } from "../libraries/vamm-utils/VammTicks.sol";
import { liquidityFromBase } from "../libraries/vamm-utils/VammHelpers.sol";
import { FilledBalances, UnfilledBalances, PositionBalances, MakerOrderParams } from "../libraries/DataTypes.sol";

import { SafeCastU128, SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { IPool } from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { SD59x18 } from "@prb/math/SD59x18.sol";

contract PoolModule is IPoolModule {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using VammTicks for DatedIrsVamm.Data;
    using SetUtil for SetUtil.UintSet;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    /**
     * @inheritdoc IPool
     */
    function name() external pure override returns (string memory) {
        return "Dated Irs Pool";
    }

    /**
     * @inheritdoc IPool
     */
    function executeDatedTakerOrder(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount,
        uint160 sqrtPriceLimitX96,
        UD60x18 markPrice,
        UD60x18 markPriceBand
    )
        external
        override
        returns (PositionBalances memory)
    {
        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }

        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        if (sqrtPriceLimitX96 == 0) {
            VammTicks.TickLimits memory currentTickLimits = vamm.getCurrentTickLimits(markPrice, markPriceBand);

            sqrtPriceLimitX96 = (
                baseAmount > 0 // long
                    ? currentTickLimits.minSqrtRatio + 1
                    : currentTickLimits.maxSqrtRatio - 1
            );
        }

        return vamm.vammSwap(
            DatedIrsVamm.SwapParams({
                amountSpecified: -baseAmount,
                sqrtPriceLimitX96: sqrtPriceLimitX96,
                markPrice: markPrice,
                markPriceBand: markPriceBand
            })
        );
    }

    /**
     * @inheritdoc IPool
     */
    function executeDatedMakerOrder(MakerOrderParams memory params) external override {
        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "executeDatedMakerOrder");
        }

        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(params.marketId, params.maturityTimestamp);

        int128 liquidityDelta = liquidityFromBase(params.baseDelta, params.tickLower, params.tickUpper);

        vamm.executeDatedMakerOrder(params.accountId, params.tickLower, params.tickUpper, liquidityDelta);
    }

    /**
     * @inheritdoc IPool
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        override
        returns (int256 closedUnfilledBasePool)
    {
        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "closeUnfilledBase");
        }

        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        uint256[] memory positions = vamm.vars.accountPositions[accountId].values();

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data memory position = LPPosition.exists(positions[i].to128());

            vamm.executeDatedMakerOrder(accountId, position.tickLower, position.tickUpper, -position.liquidity.toInt());

            (uint256 absClosedBase, ) = VammHelpers.amountsFromLiquidity(
                position.liquidity,
                position.tickLower,
                position.tickUpper
            );

            closedUnfilledBasePool += absClosedBase.toInt();
        }
    }

    /**
     * @inheritdoc IPool
     */
    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        override
        returns (FilledBalances memory)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountFilledBalances(accountId);
    }

    /**
     * @inheritdoc IPool
     */
    function getAccountUnfilledBaseAndQuote(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        override
        returns (UnfilledBalances memory)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.getAccountUnfilledBalances(accountId);
    }

    /**
     * @inheritdoc IPool
     */
    function getAdjustedTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 orderSizeWad,
        uint32 lookbackWindow
    )
        external
        view
        override
        returns (UD60x18)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return Twap.twap(vamm, lookbackWindow, SD59x18.wrap(orderSizeWad));
    }

    /**
     * @inheritdoc IPool
     */
    function hasUnfilledOrders(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (bool)
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        uint256[] memory positions = vamm.vars.accountPositions[accountId].values();

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());
            if (position.liquidity > 0) {
                return true;
            }
        }

        return false;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPool).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
