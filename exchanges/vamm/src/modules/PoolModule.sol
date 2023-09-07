// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/UD60x18.sol";

import "../libraries/vamm-utils/Twap.sol";
import "../storage/DatedIrsVamm.sol";
import "../interfaces/IPoolModule.sol";
import {PoolConfiguration} from "../storage/PoolConfiguration.sol";

import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import "oz/utils/math/SignedMath.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPoolModule {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU128 for uint128;
    using VammTicks for DatedIrsVamm.Data;
    using Twap for DatedIrsVamm.Data;

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
        returns (int256 executedBaseAmount, int256 executedQuoteAmount) {
        
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

        (executedQuoteAmount, executedBaseAmount) = vamm.vammSwap(swapParams);
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

        vamm.executeDatedMakerOrder(accountId, marketId, tickLower, tickUpper, liquidityDelta);

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

        uint128[] memory positions = vamm.vars.positionsInAccount[accountId];

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data memory position = LPPosition.exists(positions[i]);
            vamm.executeDatedMakerOrder(
                accountId, 
                marketId,
                position.tickLower,
                position.tickUpper,
                -position.liquidity.toInt()
            );
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
        returns (int256 baseBalancePool, int256 quoteBalancePool){     
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
        returns (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort
        ) {      
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        (unfilledBaseLong, unfilledBaseShort, unfilledQuoteLong, unfilledQuoteShort) = vamm.getAccountUnfilledBalances(accountId);
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
        bool nonZeroOrderSize = orderSizeWad != 0;
        return getDatedIRSTwap(marketId, maturityTimestamp, orderSizeWad, lookbackWindow, nonZeroOrderSize, nonZeroOrderSize);
    }

    function getDatedIRSTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 orderSizeWad,
        uint32 lookbackWindow,
        bool adjustForPriceImpact,
        bool adjustForSpread
    ) 
        public view override returns (UD60x18 datedIRSTwap) 
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        datedIRSTwap = vamm.twap(lookbackWindow, orderSizeWad, adjustForPriceImpact, adjustForSpread);
    }
}
