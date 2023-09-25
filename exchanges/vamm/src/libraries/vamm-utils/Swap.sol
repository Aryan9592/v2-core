//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { PoolConfiguration } from "../../storage/PoolConfiguration.sol";
import { Oracle } from "../../storage/Oracle.sol";

import { LiquidityMath } from "../math/LiquidityMath.sol";
import { Time } from "../time/Time.sol";
import { SwapMath } from "./SwapMath.sol";
import { TickMath } from "../ticks/TickMath.sol";
import { VammHelpers } from "./VammHelpers.sol";
import { VammTicks } from "./VammTicks.sol";
import { Tick } from "../ticks/Tick.sol";

import { VammCustomErrors } from "./VammCustomErrors.sol";
import { TickBitmap } from "../ticks/TickBitmap.sol";

import { UD60x18, ud, convert as convert_ud } from "@prb/math/UD60x18.sol";

import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {MTMAccruedInterest} from  "@voltz-protocol/util-contracts/src/commons/MTMAccruedInterest.sol";

library Swap {
    using TickBitmap for mapping(int16 => uint256);
    using SafeCastU256 for uint256;
    using Tick for mapping(int24 => Tick.Info);
    using Oracle for Oracle.Observation[65535];
    using DatedIrsVamm for DatedIrsVamm.Data;
    
    /// @dev Stores fixed values required in each swap step 
    struct SwapFixedValues {
        uint256 secondsTillMaturity;
        VammTicks.TickLimits tickLimits;
        UD60x18 liquidityIndex;
    }

    function vammSwap(
        DatedIrsVamm.Data storage self,
        DatedIrsVamm.SwapParams memory params
    )
        internal
        lock(self)
        returns (int256 quoteTokenDelta, int256 baseTokenDelta)
    {
        Time.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        SwapFixedValues memory swapFixedValues = SwapFixedValues({
            secondsTillMaturity: self.immutableConfig.maturityTimestamp - block.timestamp,
            tickLimits: VammTicks.getCurrentTickLimits(self, params.markPrice, params.markPriceBand),
            liquidityIndex: PoolConfiguration.getRateOracle(self.immutableConfig.marketId).getCurrentIndex()
        });

        if (params.amountSpecified == 0) {
            revert VammCustomErrors.IRSNotionalAmountSpecifiedMustBeNonZero();
        }

        /// @dev if a trader is an FT, they consume fixed in return for variable
        /// @dev Movement from right to left along the VAMM, hence the sqrtPriceLimitX96 needs to be higher 
        // than the current sqrtPriceX96, but lower than the MAX_SQRT_RATIO
        /// @dev if a trader is a VT, they consume variable in return for fixed
        /// @dev Movement from left to right along the VAMM, hence the sqrtPriceLimitX96 needs to be lower 
        // than the current sqrtPriceX96, but higher than the MIN_SQRT_RATIO

        require(
            params.amountSpecified > 0
                ? params.sqrtPriceLimitX96 > self.vars.sqrtPriceX96 &&
                    params.sqrtPriceLimitX96 < swapFixedValues.tickLimits.maxSqrtRatio
                : params.sqrtPriceLimitX96 < self.vars.sqrtPriceX96 &&
                    params.sqrtPriceLimitX96 > swapFixedValues.tickLimits.minSqrtRatio,
            "SPL"
        );
        
        self.vars.trackerAccruedInterestGrowthGlobalX128 = 
            MTMAccruedInterest.getMTMAccruedInterestTrackers(
                self.vars.trackerAccruedInterestGrowthGlobalX128,
                VammHelpers.getNewMTMTimestampAndRateIndex(
                    self.immutableConfig.marketId, 
                    self.immutableConfig.maturityTimestamp
                ),
                self.vars.trackerBaseTokenGrowthGlobalX128,
                self.vars.trackerQuoteTokenGrowthGlobalX128
            );

        VammHelpers.SwapState memory state = VammHelpers.SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            liquidity: self.vars.liquidity,
            trackerQuoteTokenGrowthGlobalX128: self.vars.trackerQuoteTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128,
            trackerAccruedInterestGrowthGlobalX128: self.vars.trackerAccruedInterestGrowthGlobalX128.accruedInterest,
            quoteTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
            baseTokenDeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // continue swapping as long as we haven't used the entire input/output and haven't 
        //     reached the price (implied fixed rate) limit
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != params.sqrtPriceLimitX96
        ) {
            VammHelpers.StepComputations memory step;

            ///// GET NEXT TICK /////

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            /// @dev if isFT (fixed taker) (moving right to left), 
            ///     the nextInitializedTick should be more than or equal to the current tick
            /// @dev if !isFT (variable taker) (moving left to right), 
            ///     the nextInitializedTick should be less than or equal to the current tick
            /// add a test for the statement that checks for the above two conditions
            (step.tickNext, step.initialized) = self.vars.tickBitmap
                .nextInitializedTickWithinOneWord(state.tick, self.immutableConfig.tickSpacing, !(params.amountSpecified > 0));

            // ensure that we do not overshoot the min/max tick, as the tick bitmap is not aware of these bounds
            if (params.amountSpecified > 0 && step.tickNext > swapFixedValues.tickLimits.maxTick) {
                step.tickNext = swapFixedValues.tickLimits.maxTick;
            }
            if (!(params.amountSpecified > 0) && step.tickNext < swapFixedValues.tickLimits.minTick) {
                step.tickNext = swapFixedValues.tickLimits.minTick;
            }
            // get the price for the next tick
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.tickNext);

            ///// GET SWAP RESULTS /////

            // compute values to swap to the target tick, price limit, or point where input/output amount is exhausted
            /// @dev for a Fixed Taker (isFT) if the sqrtPriceNextX96 is larger than the limit, 
            ///     then the target price passed into computeSwapStep is sqrtPriceLimitX96
            /// @dev for a Variable Taker (!isFT) if the sqrtPriceNextX96 is lower than the limit, 
            ///     then the target price passed into computeSwapStep is sqrtPriceLimitX96
            (
                state.sqrtPriceX96,
                step.amountIn,
                step.amountOut
            ) = SwapMath.computeSwapStep(
                SwapMath.SwapStepParams({
                    sqrtRatioCurrentX96: state.sqrtPriceX96,
                    sqrtRatioTargetX96: VammTicks.getSqrtRatioTargetX96(
                        params.amountSpecified,
                        step.sqrtPriceNextX96,
                        params.sqrtPriceLimitX96
                    ),
                    liquidity: state.liquidity,
                    amountRemaining: state.amountSpecifiedRemaining,
                    timeToMaturityInSeconds: swapFixedValues.secondsTillMaturity
                })
            );

            // mapping amount in and amount out to the corresponding deltas
            // along the 2 axes of the vamm
            if (params.amountSpecified > 0) {
                // LP is a Variable Taker
                step.baseTokenDelta = step.amountIn.toInt(); // this is positive
                step.averagePrice = ud(step.amountOut).div(ud(step.amountIn)).div(convert_ud(100));
            } else {
                // LP is a Fixed Taker
                step.baseTokenDelta = -step.amountOut.toInt(); // this is negative
                step.averagePrice = ud(step.amountIn).div(ud(step.amountOut)).div(convert_ud(100));
            }

            ///// UPDATE TRACKERS /////
            state.amountSpecifiedRemaining -= step.baseTokenDelta;
            if (state.liquidity > 0) {
                step.quoteTokenDelta = VammHelpers.calculateQuoteTokenDelta(
                    step.baseTokenDelta,
                    step.averagePrice,
                    self.mutableConfig.spread,
                    self.immutableConfig.marketId
                );

                (
                    state.trackerQuoteTokenGrowthGlobalX128,
                    state.trackerBaseTokenGrowthGlobalX128
                ) = VammHelpers.calculateGlobalTrackerValues(
                    state,
                    step.quoteTokenDelta,
                    step.baseTokenDelta
                );

                state.quoteTokenDeltaCumulative -= step.quoteTokenDelta; // opposite sign from that of the LP's
                state.baseTokenDeltaCumulative -= step.baseTokenDelta; // opposite sign from that of the LP's
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 liquidityNet = self.vars.ticks.cross(
                        step.tickNext,
                        state.trackerQuoteTokenGrowthGlobalX128,
                        state.trackerBaseTokenGrowthGlobalX128,
                        state.trackerAccruedInterestGrowthGlobalX128,
                        self.immutableConfig.marketId,
                        self.immutableConfig.maturityTimestamp
                    );

                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity,
                        params.amountSpecified > 0 ? liquidityNet : -liquidityNet
                    );

                }

                state.tick = params.amountSpecified > 0 ? step.tickNext : (step.tickNext - 1);
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                // recompute unless we're on a lower tick boundary (i.e. already transitioned ticks), and haven't moved
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }

        ///// UPDATE VAMM VARS AFTER SWAP /////
        if (state.tick != self.vars.tick) {
            // update the tick in case it changed
            (self.vars.observationIndex, self.vars.observationCardinality) = self.vars.observations.write(
                self.vars.observationIndex,
                Time.blockTimestampTruncated(),
                self.vars.tick,
                self.vars.observationCardinality,
                self.vars.observationCardinalityNext,
                self.mutableConfig.minSecondsBetweenOracleObservations
            );
            (self.vars.sqrtPriceX96, self.vars.tick ) = (
                state.sqrtPriceX96,
                state.tick
            );
        } else {
            // otherwise just update the price
            self.vars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        self.vars.liquidity = state.liquidity;

        self.vars.trackerBaseTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128;
        self.vars.trackerQuoteTokenGrowthGlobalX128 = state.trackerQuoteTokenGrowthGlobalX128;

        emit VammHelpers.VAMMPriceChange(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            self.vars.tick,
            block.timestamp
        );

        emit VammHelpers.Swap(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            msg.sender,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            quoteTokenDelta,
            baseTokenDelta,
            block.timestamp
        );

        return (state.quoteTokenDeltaCumulative, state.baseTokenDeltaCumulative);
    }

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock(DatedIrsVamm.Data storage self) {
        if (!self.vars.unlocked) {
            revert VammCustomErrors.Lock(true);
        }
        self.vars.unlocked = false;
        _;
        if (self.vars.unlocked) {
            revert VammCustomErrors.Lock(false);
        }
        self.vars.unlocked = true;
    }
}