// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;


import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";

import { PositionBalances, FilledBalances, UnfilledBalances, RateOracleObservation } from "../DataTypes.sol";

import { Tick } from "../ticks/Tick.sol";

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { LPPosition } from "../../storage/LPPosition.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256, SafeCastU128 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { SignedMath } from "oz/utils/math/SignedMath.sol";

import { UD60x18, ud, convert } from "@prb/math/UD60x18.sol";

import { mulUDxUint, divUintUD } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import { TraderPosition } from "@voltz-protocol/products-dated-irs/src/libraries/TraderPosition.sol";


library AccountBalances {
    using LPPosition for LPPosition.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SetUtil for SetUtil.UintSet;
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Tick for mapping(int24 => Tick.Info);

    function getAccountUnfilledBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (UnfilledBalances memory unfilled)
    {
        uint256[] memory positions = self.vars.accountPositions[accountId].values();

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            if (position.tickLower == position.tickUpper) {
                continue;
            }
            
            {
                (uint256 unfilledBase, uint256 unfilledQuote) = getOneSideUnfilledBalances(
                    self.immutableConfig.marketId,
                    position.tickLower < self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper < self.vars.tick ? position.tickUpper : self.vars.tick,
                    position.liquidity,
                    self.mutableConfig.spread,
                    true
                );
            
                unfilled.baseLong += unfilledBase;
                unfilled.quoteLong += unfilledQuote;
            }
            
            {
                (uint256 unfilledBase, uint256 unfilledQuote) = getOneSideUnfilledBalances(
                    self.immutableConfig.marketId,
                    position.tickLower > self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper > self.vars.tick ? position.tickUpper : self.vars.tick,
                    position.liquidity,
                    self.mutableConfig.spread,
                    false
                );

                unfilled.baseShort += unfilledBase;
                unfilled.quoteShort += unfilledQuote;
            }
        }
    }

    function getAccountFilledBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (FilledBalances memory balances) {

        uint256[] memory positions = self.vars.accountPositions[accountId].values();

        RateOracleObservation memory rateOracleObservation = self.getLatestRateIndex();
        
        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            PositionBalances memory it = position.getUpdatedPositionBalances(
                computeGrowthInside(self, position.tickLower, position.tickUpper)
            ); 

            balances.base += it.base;
            balances.quote += it.quote;
            balances.accruedInterest += TraderPosition.getAccruedInterest(it, rateOracleObservation);
        }

    }

    function getOneSideUnfilledBalances(
        uint128 marketId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        UD60x18 spread,
        bool isLong
    ) private view returns (uint256 unfilledBase, uint256 unfilledQuote)
    {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        uint256 unbalancedQuote;
        (unfilledBase, unbalancedQuote) = VammHelpers.amountsFromLiquidity(
            liquidity,
            tickLower,
            tickUpper
        );

        uint256 unbalancedQuotePenalty = mulUDxUint(spread.mul(convert(100)), unfilledBase);
        uint256 remainingUnbalancedQuote = 0;

        if (isLong) {
            remainingUnbalancedQuote = unbalancedQuote + unbalancedQuotePenalty;
        }
        else {
            if (unbalancedQuotePenalty < unbalancedQuote) {
                remainingUnbalancedQuote = unbalancedQuote - unbalancedQuotePenalty;
            }
        }

        if (remainingUnbalancedQuote == 0) {
            return (unfilledBase, 0);
        }

        UD60x18 factor = VammHelpers.exposureFactor(marketId);

        unfilledQuote = divUintUD(mulUDxUint(factor, remainingUnbalancedQuote), convert(100));
    }

    function growthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        int256 growthGlobalX128,
        int256 lowerGrowthOutsideX128,
        int256 upperGrowthOutsideX128
    ) private pure returns (int256) {
        // calculate the growth below
        int256 growthBelowX128 = 
            (tickCurrent >= tickLower) 
                ? lowerGrowthOutsideX128 
                : growthGlobalX128 - lowerGrowthOutsideX128;

        // calculate the growth above
        int256 growthAboveX128 = 
            (tickCurrent < tickUpper) ? 
                upperGrowthOutsideX128 : 
                growthGlobalX128 - upperGrowthOutsideX128;

        return growthGlobalX128 - (growthBelowX128 + growthAboveX128);
    }

    function computeGrowthInside(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (PositionBalances memory growthInsideX128)
    {
        VammTicks.checkTicksLimits(tickLower, tickUpper);

        Tick.Info memory lower = self.vars.ticks[tickLower];
        Tick.Info memory upper = self.vars.ticks[tickUpper];

        growthInsideX128.base = growthInside(
            tickLower,
            tickUpper,
            self.vars.tick,
            self.vars.growthGlobalX128.base,
            lower.growthOutsideX128.base,
            upper.growthOutsideX128.base
        );

        growthInsideX128.quote = growthInside(
            tickLower,
            tickUpper,
            self.vars.tick,
            self.vars.growthGlobalX128.quote,
            lower.growthOutsideX128.quote,
            upper.growthOutsideX128.quote
        );

        growthInsideX128.extraCashflow = growthInside(
            tickLower,
            tickUpper,
            self.vars.tick,
            self.vars.growthGlobalX128.extraCashflow,
            lower.growthOutsideX128.extraCashflow,
            upper.growthOutsideX128.extraCashflow
        );
    }
}
