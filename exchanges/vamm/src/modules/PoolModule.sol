// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;


import { IPoolModule } from "../interfaces/IPoolModule.sol";

import { DatedIrsVamm } from "../storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "../storage/PoolConfiguration.sol";
import { LPPosition } from "../storage/LPPosition.sol";

import { TickMath } from "../libraries/ticks/TickMath.sol";
import { Twap } from "../libraries/vamm-utils/Twap.sol";
import { VammTicks } from "../libraries/vamm-utils/VammTicks.sol";
import { VammHelpers } from "../libraries/vamm-utils/VammHelpers.sol";
import { FilledBalances, UnfilledBalances, PositionBalances } from "../libraries/DataTypes.sol";

import { SafeCastU128, SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { IPool } from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { SD59x18 } from "@prb/math/SD59x18.sol";


/// @title Interface a Pool needs to adhere.
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

    /// @notice returns a human-readable name for a given pool
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
        external override
        returns (PositionBalances memory /* tokenDeltas */) {
        
        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }
        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        DatedIrsVamm.SwapParams memory swapParams;
        swapParams.amountSpecified = -baseAmount;
        if (sqrtPriceLimitX96 == 0) {
            VammTicks.TickLimits memory currentTickLimits = vamm.getCurrentTickLimits(markPrice, markPriceBand);
            swapParams.sqrtPriceLimitX96 = (
                baseAmount > 0 // VT
                    ? currentTickLimits.minSqrtRatio + 1
                    : currentTickLimits.maxSqrtRatio - 1
            );
        } else {
            swapParams.sqrtPriceLimitX96 = sqrtPriceLimitX96;
        }
        swapParams.markPrice = markPrice;
        swapParams.markPriceBand = markPriceBand;

        return vamm.vammSwap(swapParams);
    }

    /**
     * @inheritdoc IPool
     */
    function executeDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        external override returns (int256 baseAmount)
    {
        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "executeDatedMakerOrder");
        }

        PoolConfiguration.whenNotPaused();
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        vamm.executeDatedMakerOrder(accountId, tickLower, tickUpper, liquidityDelta);

        return VammHelpers.baseAmountFromLiquidity(
            liquidityDelta,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper)
        );
    }

    /**
     * @inheritdoc IPool
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external override
        returns (int256 closedUnfilledBasePool) {

        if (msg.sender != PoolConfiguration.load().marketManagerAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }
        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        uint256[] memory positions = vamm.vars.accountPositions[accountId].values();

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data memory position = LPPosition.exists(positions[i].to128());
            vamm.executeDatedMakerOrder(
                accountId, 
                position.tickLower,
                position.tickUpper,
                -position.liquidity.toInt()
            );

            // todo: shouldn't we convert liquidity to base here?
            closedUnfilledBasePool += position.liquidity.toInt();
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
        returns (FilledBalances memory) {     
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

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPool).interfaceId || interfaceId == this.supportsInterface.selector;
    }

    /**
     * @inheritdoc IPool
     */
    function getAdjustedDatedIRSTwap(uint128 marketId, uint32 maturityTimestamp, int256 orderSizeWad, uint32 lookbackWindow) 
        external view override returns (UD60x18 datedIRSTwap) 
    {   
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSTwap = Twap.twap(vamm, lookbackWindow, SD59x18.wrap(orderSizeWad));
    }

    function hasUnfilledOrders(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    ) external view returns (bool) {
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
}
