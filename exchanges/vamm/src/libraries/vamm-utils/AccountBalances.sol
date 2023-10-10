// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { LPPosition } from "../../storage/LPPosition.sol";
import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";

import { UD60x18, ud,  convert, unwrap } from "@prb/math/UD60x18.sol";

import { Tick } from "../ticks/Tick.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256, SafeCastU128 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import {SignedMath} from "oz/utils/math/SignedMath.sol";

import { FilledBalances, UnfilledBalances } from "@voltz-protocol/products-dated-irs/src/libraries/DataTypes.sol";

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
                    position.liquidity.toInt(),
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
                    position.liquidity.toInt(),
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
        
        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            FilledBalances memory it = position.getUpdatedPositionBalances(
                self.immutableConfig.marketId,
                self.immutableConfig.maturityTimestamp,
                computeGrowthInside(self, position.tickLower, position.tickUpper)
            ); 

            balances.base += it.base;
            balances.quote += it.quote;
            balances.accruedInterest += it.accruedInterest;
        }

    }

    function getOneSideUnfilledBalances(
        uint128 marketId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity,
        UD60x18 spread,
        bool isLong
    ) private view returns (uint256 /* unfilledBase */ , uint256 /* unfilledQuote */)
    {
        if (tickLower == tickUpper) {
            return (0, 0);
        }

        uint256 unfilledBase = VammHelpers.baseBetweenTicks(
            tickLower,
            tickUpper,
            liquidity
        ).toUint();

        if (unfilledBase == 0) {
            return (0, 0);
        }
        
        int256 unbalancedQuoteTokens = VammHelpers.unbalancedQuoteBetweenTicks(
            tickLower,
            tickUpper,
            (isLong) ? -unfilledBase.toInt() : unfilledBase.toInt()
        );

        // note calculateQuoteTokenDelta considers spread in advantage (for LPs)
        int256 unfilledQuote = VammHelpers.calculateQuoteTokenDelta(
            (isLong) ? -unfilledBase.toInt() : unfilledBase.toInt(),
            ud(SignedMath.abs(unbalancedQuoteTokens)).div(ud(unfilledBase)).div(convert(100)),
            spread,
            marketId
        );

        uint256 absUnfilledQuote = ((isLong) ? unfilledQuote : -unfilledQuote).toUint();

        return (unfilledBase, absUnfilledQuote);
    }

    function computeGrowthInside(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (FilledBalances memory growthInsideX128)
    {
        VammTicks.checkTicksLimits(tickLower, tickUpper);

        growthInsideX128.base = self.vars.ticks.getBaseTokenGrowthInside(
            Tick.BaseTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                baseTokenGrowthGlobalX128: self.vars.growthGlobalX128.base
            })
        );

        growthInsideX128.quote = self.vars.ticks.getQuoteTokenGrowthInside(
            Tick.QuoteTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                quoteTokenGrowthGlobalX128: self.vars.growthGlobalX128.quote
            })
        );

        growthInsideX128.accruedInterest = self.vars.ticks.getAccruedInterestGrowthInside(
            Tick.AccruedInterestGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                growthGlobalX128: self.vars.growthGlobalX128,
                marketId: self.immutableConfig.marketId,
                maturityTimestamp: self.immutableConfig.maturityTimestamp
            })
        );
    }
}
