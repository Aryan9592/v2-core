// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "../../storage/PoolConfiguration.sol";
import { LPPosition } from "../../storage/LPPosition.sol";
import { FixedAndVariableMath } from "../math/FixedAndVariableMath.sol";
import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256, SafeCastU128 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

library AccountBalances {
    using LPPosition for LPPosition.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SetUtil for SetUtil.UintSet;

    function getAccountUnfilledBalances(
        DatedIrsVamm.Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (DatedIrsVamm.UnfilledBalances memory unfilled)
    {
        uint256[] memory positions = self.vars.accountPositions[accountId].values();

        UD60x18 liquidityIndex = PoolConfiguration
            .getRateOracle(self.immutableConfig.marketId)
            .getCurrentIndex();

        UD60x18 timeDelta = FixedAndVariableMath.accrualFact(
            self.immutableConfig.maturityTimestamp - block.timestamp
        );

        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            if (position.tickLower == position.tickUpper) {
                continue;
            }
            
            {
                (uint256 unfilledBase, uint256 unfilledQuote) = getOneSideUnfilledBalances(
                    position.tickLower < self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper < self.vars.tick ? position.tickUpper : self.vars.tick,
                    position.liquidity.toInt(),
                    timeDelta,
                    liquidityIndex,
                    self.mutableConfig.spread,
                    true
                );
            
                unfilled.baseLong += unfilledBase;
                unfilled.quoteLong += unfilledQuote;
            }
            
            {
                (uint256 unfilledBase, uint256 unfilledQuote) = getOneSideUnfilledBalances(
                    position.tickLower > self.vars.tick ? position.tickLower : self.vars.tick,
                    position.tickUpper > self.vars.tick ? position.tickUpper : self.vars.tick,
                    position.liquidity.toInt(),
                    timeDelta,
                    liquidityIndex,
                    self.mutableConfig.spread,
                    true
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
        returns (int256 baseBalancePool, int256 quoteBalancePool) {

        uint256[] memory positions = self.vars.accountPositions[accountId].values();
        
        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            (int256 trackerQuoteTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
        
            (int256 trackerQuoteTokenAccumulated, int256 trackerBaseTokenAccumulated) = 
                position.getUpdatedPositionBalances(trackerQuoteTokenGlobalGrowth, trackerBaseTokenGlobalGrowth); 

            baseBalancePool += trackerBaseTokenAccumulated;
            quoteBalancePool += trackerQuoteTokenAccumulated;
        }

    }

    function getOneSideUnfilledBalances(
        int24 tickLower,
        int24 tickUpper,
        int128 liquidity,
        UD60x18 timeDelta,
        UD60x18 liquidityIndex,
        UD60x18 spread,
        bool isLong
    ) private pure returns (uint256 /* unfilledBase */ , uint256 /* unfilledQuote */)
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

        /// @notice: calculateQuoteTokenDelta considers spread in advantage (for LPs)
        int256 unfilledQuote = VammHelpers.calculateQuoteTokenDelta(
            unbalancedQuoteTokens,
            (isLong) ? -unfilledBase.toInt() : unfilledBase.toInt(),
            timeDelta,
            liquidityIndex,
            spread
        );

        uint256 absUnfilledQuote = ((isLong) ? unfilledQuote : -unfilledQuote).toUint();

        return (unfilledBase, absUnfilledQuote);
    }

    function growthBetweenTicks(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (
        int256 trackerQuoteTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween
    )
    {
        VammTicks.checkTicksLimits(tickLower, tickUpper);

        int256 trackerQuoteTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self.vars.tick) {
            trackerQuoteTokenBelowLowerTick = self.vars.ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenBelowLowerTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars.ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars.ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerQuoteTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerQuoteTokenAboveUpperTick = self.vars.ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenAboveUpperTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars.ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars.ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerQuoteTokenGrowthBetween = 
            self.vars.trackerQuoteTokenGrowthGlobalX128 - trackerQuoteTokenBelowLowerTick - trackerQuoteTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = 
            self.vars.trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;
    }
}
