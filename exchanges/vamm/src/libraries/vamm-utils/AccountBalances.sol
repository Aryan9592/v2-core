// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { amountsFromLiquidity, calculatePrice, applySpread } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";

import { PositionBalances, UnfilledBalances, RateOracleObservation } from "../DataTypes.sol";

import { Tick } from "../ticks/Tick.sol";

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { LPPosition } from "../../storage/LPPosition.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256, SafeCastU128 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Account balances library
 * @notice Libary that helps calculate the filled and unfilled balances of an account
 */
library AccountBalances {
    using LPPosition for LPPosition.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SetUtil for SetUtil.UintSet;
    using DatedIrsVamm for DatedIrsVamm.Data;
    using Tick for mapping(int24 => Tick.Info);

    /**
     * @notice For a given LP account, returns how much liquidity is available to trade in each direction.
     * @param self VAMM state
     * @param accountId The LP account. All positions within the account will be considered
     * @return unfilled The unfilled base and quote balances
     */
    function getAccountUnfilledBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (UnfilledBalances memory unfilled)
    {
        uint256[] memory positions = self.vars.accountPositions[accountId].values();
        UD60x18 exposureFactor = self.getExposureFactor();

        uint256 unbalancedQuoteLong;
        uint256 unbalancedQuoteShort;

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            if (position.tickLower == position.tickUpper) {
                continue;
            }

            {
                (uint256 unfilledBase, uint256 unbalancedQuote) = amountsFromLiquidity(
                    position.liquidity,
                    position.tickLower < self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper < self.vars.tick ? position.tickUpper : self.vars.tick
                );

                unfilled.baseLong += unfilledBase;
                unbalancedQuoteLong += unbalancedQuote;
            }

            {
                (uint256 unfilledBase, uint256 unbalancedQuote) = amountsFromLiquidity(
                    position.liquidity,
                    position.tickLower > self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper > self.vars.tick ? position.tickUpper : self.vars.tick
                );

                unfilled.baseShort += unfilledBase;
                unbalancedQuoteShort += unbalancedQuote;
            }
        }

        if (unfilled.baseLong > 0) {
            unfilled.averagePriceLong =
                applySpread(calculatePrice(unfilled.baseLong, unbalancedQuoteLong), self.mutableConfig.spread, false);

            unfilled.quoteLong = mulUDxUint(exposureFactor.mul(unfilled.averagePriceLong), unfilled.baseLong);
        }

        if (unfilled.baseShort > 0) {
            unfilled.averagePriceShort =
                applySpread(calculatePrice(unfilled.baseShort, unbalancedQuoteShort), self.mutableConfig.spread, true);

            unfilled.quoteShort = mulUDxUint(exposureFactor.mul(unfilled.averagePriceShort), unfilled.baseShort);
        }
    }

    /**
     * @notice For a given LP posiiton, returns how much of it is already traded and what are base and
     * quote tokens representing those exiting trades
     * @param self VAMM state
     * @param accountId The LP account. All positions within the account will be considered
     * @return balances The filled balances of the given account in the VAMM
     */
    function getAccountPositionBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (PositionBalances memory balances)
    {
        uint256[] memory positions = self.vars.accountPositions[accountId].values();

        RateOracleObservation memory rateOracleObservation = self.getLatestRateIndex();

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            PositionBalances memory it =
                position.getUpdatedPositionBalances(computeGrowthInside(self, position.tickLower, position.tickUpper));

            balances.base += it.base;
            balances.quote += it.quote;
            balances.extraCashflow += it.extraCashflow;
        }
    }

    /**
     * @notice Computes the growth inside a given tick range given the current tick in the VAMM
     * @param tickLower The lower tick of the range
     * @param tickUpper The upper tick of the range
     * @param growthGlobalX128 Global growth
     * @param lowerGrowthOutsideX128 Growth outside the range, on the lower side
     * @param upperGrowthOutsideX128 Growth outside the range, on the upper side
     * @return growthInside Growth inside the range
     */
    function growthInside(
        int24 tickLower,
        int24 tickUpper,
        int24 tickCurrent,
        int256 growthGlobalX128,
        int256 lowerGrowthOutsideX128,
        int256 upperGrowthOutsideX128
    )
        private
        pure
        returns (int256)
    {
        // calculate the growth below
        int256 growthBelowX128 =
            (tickCurrent >= tickLower) ? lowerGrowthOutsideX128 : growthGlobalX128 - lowerGrowthOutsideX128;

        // calculate the growth above
        int256 growthAboveX128 =
            (tickCurrent < tickUpper) ? upperGrowthOutsideX128 : growthGlobalX128 - upperGrowthOutsideX128;

        return growthGlobalX128 - (growthBelowX128 + growthAboveX128);
    }

    /**
     * @notice Computes the current growth inside of the base, quote and cashflow for a given tick range
     * given the current tick in the VAMM
     * @param self The VAMM state
     * @param tickLower The lower tick of the position
     * @param tickUpper The upper tick of the position
     * @return growthInsideX128 Growth Inside given tick range
     */
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
