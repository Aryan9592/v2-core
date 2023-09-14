// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "../../storage/PoolConfiguration.sol";
import { LPPosition } from "../../storage/LPPosition.sol";
import { FixedAndVariableMath } from "../math/FixedAndVariableMath.sol";
import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";

import { UD60x18, ud } from "@prb/math/UD60x18.sol";

import {ExposureHelpers} from "@voltz-protocol/products-dated-irs/src/libraries/ExposureHelpers.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256, SafeCastU128 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

import {SignedMath} from "oz/utils/math/SignedMath.sol";

library AccountBalances {
    using LPPosition for LPPosition.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using SetUtil for SetUtil.UintSet;
    using DatedIrsVamm for DatedIrsVamm.Data;

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
        returns (int256 baseBalancePool, int256 quoteBalancePool, int256 accruedInterestPool) {

        uint256[] memory positions = self.vars.accountPositions[accountId].values();
        
        for (uint256 i = 0; i < positions.length; i++) {
            LPPosition.Data storage position = LPPosition.exists(positions[i].to128());

            (int256 trackerQuoteTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth, int256 trackerAccruedInterestGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
        
            (int256 trackerQuoteTokenAccumulated, int256 trackerBaseTokenAccumulated, int256 trackerAccruedInterestAccumulated) = 
                position.getUpdatedPositionBalances(trackerQuoteTokenGlobalGrowth, trackerBaseTokenGlobalGrowth, trackerAccruedInterestGlobalGrowth); 

            baseBalancePool += trackerBaseTokenAccumulated;
            quoteBalancePool += trackerQuoteTokenAccumulated;
            accruedInterestPool += trackerAccruedInterestAccumulated;
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
            ud(SignedMath.abs(unbalancedQuoteTokens)).div(ud(unfilledBase)),
            spread,
            marketId
        );

        uint256 absUnfilledQuote = ((isLong) ? unfilledQuote : -unfilledQuote).toUint();

        return (unfilledBase, absUnfilledQuote);
    }

    struct GrowthBetweenTickVars {
        uint256 newMTMTimestamp;
        UD60x18 newMTMRateIndex;
        int256 latestLowerTrackerAccruedInterestGrowthOutsideX128;
        int256 latestUpperTrackerAccruedInterestGrowthOutsideX128;
        int256 latestTrackerAccruedInterestGrowthGlobalX128;
    }

    function growthBetweenTicks(
        DatedIrsVamm.Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) private view returns (
        int256 trackerQuoteTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween,
        int256 trackerAccruedInterestGrowthBetween
    )
    {
        VammTicks.checkTicksLimits(tickLower, tickUpper);

        GrowthBetweenTickVars memory vars;

        (vars.newMTMTimestamp, vars.newMTMRateIndex) = 
            self.getNewMTMTimestampAndRateIndex();

        int256 trackerQuoteTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;
        int256 trackerAccruedInterestBelowLowerTick;

        vars.latestLowerTrackerAccruedInterestGrowthOutsideX128 = 
            self.vars.ticks[tickLower].trackerAccruedInterestGrowthOutsideX128 +
            ExposureHelpers.getMTMAccruedInterest(
                self.vars.ticks[tickLower].trackerBaseTokenGrowthOutsideX128,
                self.vars.ticks[tickLower].trackerQuoteTokenGrowthOutsideX128,
                self.vars.ticks[tickLower].trackerLastMTMTimestampOutside,
                vars.newMTMTimestamp,
                self.vars.ticks[tickLower].trackerLastMTMRateIndexOutside,
                vars.newMTMRateIndex
            );
        vars.latestUpperTrackerAccruedInterestGrowthOutsideX128 = 
            self.vars.ticks[tickUpper].trackerAccruedInterestGrowthOutsideX128 +
            ExposureHelpers.getMTMAccruedInterest(
                self.vars.ticks[tickUpper].trackerBaseTokenGrowthOutsideX128,
                self.vars.ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128,
                self.vars.ticks[tickUpper].trackerLastMTMTimestampOutside,
                vars.newMTMTimestamp,
                self.vars.ticks[tickUpper].trackerLastMTMRateIndexOutside,
                vars.newMTMRateIndex
            );
        vars.latestTrackerAccruedInterestGrowthGlobalX128 = 
            self.vars.trackerAccruedInterestGrowthGlobalX128 +
            ExposureHelpers.getMTMAccruedInterest(
                self.vars.trackerBaseTokenGrowthGlobalX128,
                self.vars.trackerQuoteTokenGrowthGlobalX128,
                self.vars.trackerLastMTMTimestampGlobal,
                vars.newMTMTimestamp,
                self.vars.trackerLastMTMRateIndexGlobal,
                vars.newMTMRateIndex
            );

        if (tickLower <= self.vars.tick) {
            trackerQuoteTokenBelowLowerTick = self.vars.ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
            trackerAccruedInterestBelowLowerTick = vars.latestLowerTrackerAccruedInterestGrowthOutsideX128;
        } else {
            trackerQuoteTokenBelowLowerTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars.ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars.ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
            trackerAccruedInterestBelowLowerTick = vars.latestTrackerAccruedInterestGrowthGlobalX128 - 
                vars.latestLowerTrackerAccruedInterestGrowthOutsideX128;
        }

        int256 trackerQuoteTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;
        int256 trackerAccruedInterestAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerQuoteTokenAboveUpperTick = self.vars.ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
            trackerAccruedInterestAboveUpperTick = vars.latestUpperTrackerAccruedInterestGrowthOutsideX128;
        } else {
            trackerQuoteTokenAboveUpperTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars.ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars.ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
            trackerAccruedInterestAboveUpperTick = vars.latestTrackerAccruedInterestGrowthGlobalX128 - 
                vars.latestUpperTrackerAccruedInterestGrowthOutsideX128;
        }

        trackerQuoteTokenGrowthBetween = 
            self.vars.trackerQuoteTokenGrowthGlobalX128 - trackerQuoteTokenBelowLowerTick - trackerQuoteTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = 
            self.vars.trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;
        trackerAccruedInterestGrowthBetween = 
            vars.latestTrackerAccruedInterestGrowthGlobalX128 - trackerAccruedInterestBelowLowerTick - trackerAccruedInterestAboveUpperTick;
    }
}
