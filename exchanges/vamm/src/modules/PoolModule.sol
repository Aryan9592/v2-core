// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { UD60x18, ZERO } from "@prb/math/UD60x18.sol";

import "../interfaces/IPoolModule.sol";
import "../storage/DatedIrsVamm.sol";
import {PoolConfiguration} from "../storage/PoolConfiguration.sol";
import "@voltz-protocol/products-dated-irs/src/interfaces/IMarketManagerIRSModule.sol";
import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/// @title Interface a Pool needs to adhere.
contract PoolModule is IPoolModule {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SafeCastU128 for uint128;

    /// @notice returns a human-readable name for a given pool
    function name() external pure override returns (string memory) {
        return "Dated Irs Pool";
    }

    /**
     * @inheritdoc IPoolModule
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
        
        if (msg.sender != PoolConfiguration.load().productAddress) {
            revert NotAuthorized(msg.sender, "executeDatedTakerOrder");
        }
        PoolConfiguration.whenNotPaused();

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        DatedIrsVamm.SwapParams memory swapParams;
        swapParams.amountSpecified = -baseAmount;
        if (sqrtPriceLimitX96 == 0) {
            DatedIrsVamm.TickLimits memory currentTickLimits = vamm.getCurrentTickLimits(markPrice, markPriceBand);
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
     * @inheritdoc IPoolModule
     */
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        external override returns (uint256 fee, Account.MarginRequirement memory mr)
    {

        IMarketManagerIRSModule irsProduct = IMarketManagerIRSModule(PoolConfiguration.load().productAddress);

        IAccountModule(
            irsProduct.getCoreProxyAddress()
        ).onlyAuthorized(accountId, Account.ADMIN_PERMISSION, msg.sender);

        PoolConfiguration.whenNotPaused();
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);

        vamm.executeDatedMakerOrder(accountId, marketId, tickLower, tickUpper, liquidityDelta);

        (fee, mr) = irsProduct.propagateMakerOrder(
            accountId,
            marketId,
            maturityTimestamp,
            VAMMBase.baseAmountFromLiquidity(
                liquidityDelta,
                TickMath.getSqrtRatioAtTick(tickLower),
                TickMath.getSqrtRatioAtTick(tickUpper)
            )
        );

    }

    /**
     * @inheritdoc IPoolModule
     */
    function closeUnfilledBase(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external override
        returns (int256 closeUnfilledBasePool) {

        if (msg.sender != PoolConfiguration.load().productAddress) {
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
            closeUnfilledBasePool += position.liquidity.toInt();
        }
        
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IPoolModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
