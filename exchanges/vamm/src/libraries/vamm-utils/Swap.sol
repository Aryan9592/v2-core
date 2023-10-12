//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { SwapMath } from "./SwapMath.sol";
import { VammCustomErrors } from "./VammCustomErrors.sol";
import { VammTicks } from "./VammTicks.sol";
import { calculatePrice, applySpread } from "./VammHelpers.sol";

import { PositionBalances, SwapState, SwapStepComputations, RateOracleObservation } from "../DataTypes.sol";

import { Events } from "../Events.sol";

import { Tick } from "../ticks/Tick.sol";
import { TickBitmap } from "../ticks/TickBitmap.sol";
import { TickMath } from "../ticks/TickMath.sol";
import { LiquidityMath } from "../math/LiquidityMath.sol";
import { FixedPoint128 } from "../math/FixedPoint128.sol";
import { FullMath } from "../math/FullMath.sol";

import { DatedIrsVamm } from "../../storage/DatedIrsVamm.sol";
import { Oracle } from "../../storage/Oracle.sol";

import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import { TraderPosition } from "@voltz-protocol/products-dated-irs/src/libraries/TraderPosition.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

library Swap {
    using TickBitmap for mapping(int16 => uint256);
    using SafeCastU256 for uint256;
    using Tick for mapping(int24 => Tick.Info);
    using Oracle for Oracle.Observation[65_535];
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
        returns (PositionBalances memory tokenDeltas)
    {
        // Check if the pool is still active for orders
        {
            uint32 inactiveWindowBeforeMaturity = self.mutableConfig.inactiveWindowBeforeMaturity;

            if (block.timestamp + inactiveWindowBeforeMaturity >= self.immutableConfig.maturityTimestamp) {
                revert VammCustomErrors.CloseOrBeyondToMaturity(
                    self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp
                );
            }
        }

        RateOracleObservation memory rateOracleObservation = self.getLatestRateIndex();
        UD60x18 exposureFactor = self.getExposureFactor();

        SwapFixedValues memory swapFixedValues = SwapFixedValues({
            secondsTillMaturity: self.immutableConfig.maturityTimestamp - block.timestamp,
            tickLimits: VammTicks.getCurrentTickLimits(self, params.markPrice, params.markPriceBand),
            liquidityIndex: rateOracleObservation.rateIndex
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
                ? params.sqrtPriceLimitX96 > self.vars.sqrtPriceX96
                    && params.sqrtPriceLimitX96 < swapFixedValues.tickLimits.maxSqrtRatio
                : params.sqrtPriceLimitX96 < self.vars.sqrtPriceX96
                    && params.sqrtPriceLimitX96 > swapFixedValues.tickLimits.minSqrtRatio,
            "SPL"
        );

        SwapState memory state = SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            liquidity: self.vars.liquidity,
            growthGlobalX128: self.vars.growthGlobalX128,
            tokenDeltaCumulative: PositionBalances({ base: 0, quote: 0, extraCashflow: 0 })
        });

        // continue swapping as long as we haven't used the entire input/output and haven't
        //     reached the price (implied fixed rate) limit
        while (state.amountSpecifiedRemaining != 0 && state.sqrtPriceX96 != params.sqrtPriceLimitX96) {
            SwapStepComputations memory step;

            ///// GET NEXT TICK /////

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            /// @dev if isFT (fixed taker) (moving right to left),
            ///     the nextInitializedTick should be more than or equal to the current tick
            /// @dev if !isFT (variable taker) (moving left to right),
            ///     the nextInitializedTick should be less than or equal to the current tick
            /// add a test for the statement that checks for the above two conditions
            (step.tickNext, step.initialized) = self.vars.tickBitmap.nextInitializedTickWithinOneWord(
                state.tick, self.immutableConfig.tickSpacing, !(params.amountSpecified > 0)
            );

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
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
                SwapMath.SwapStepParams({
                    sqrtRatioCurrentX96: state.sqrtPriceX96,
                    sqrtRatioTargetX96: VammTicks.getSqrtRatioTargetX96(
                        params.amountSpecified, step.sqrtPriceNextX96, params.sqrtPriceLimitX96
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
                step.tokenDeltas.base = step.amountIn.toInt(); // this is positive

                step.averagePrice =
                    applySpread(calculatePrice(step.amountIn, step.amountOut), self.mutableConfig.spread, true);
            } else {
                // LP is a Fixed Taker
                step.tokenDeltas.base = -step.amountOut.toInt(); // this is negative

                step.averagePrice =
                    applySpread(calculatePrice(step.amountOut, step.amountIn), self.mutableConfig.spread, false);
            }

            ///// UPDATE TRACKERS /////
            state.amountSpecifiedRemaining -= step.tokenDeltas.base;
            if (state.liquidity > 0) {
                step.tokenDeltas.quote = -mulUDxInt(exposureFactor.mul(step.averagePrice), step.tokenDeltas.base);

                step.tokenDeltas.extraCashflow =
                    TraderPosition.computeCashflow(step.tokenDeltas.base, step.tokenDeltas.quote, rateOracleObservation);

                state.growthGlobalX128 = calculateGlobalTrackerValues(state, step.tokenDeltas);

                state.tokenDeltaCumulative.base -= step.tokenDeltas.base;
                state.tokenDeltaCumulative.quote -= step.tokenDeltas.quote;
                state.tokenDeltaCumulative.extraCashflow -= step.tokenDeltas.extraCashflow;
            }

            ///// UPDATE TICK AFTER SWAP STEP /////

            // shift tick if we reached the next price
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                // if the tick is initialized, run the tick transition
                if (step.initialized) {
                    int128 liquidityNet = self.vars.ticks.cross(step.tickNext, state.growthGlobalX128);

                    state.liquidity = LiquidityMath.addDelta(
                        state.liquidity, params.amountSpecified > 0 ? liquidityNet : -liquidityNet
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
            (self.vars.sqrtPriceX96, self.vars.tick) = (state.sqrtPriceX96, state.tick);
        } else {
            // otherwise just update the price
            self.vars.sqrtPriceX96 = state.sqrtPriceX96;
        }

        self.vars.liquidity = state.liquidity;
        self.vars.growthGlobalX128 = state.growthGlobalX128;

        emit Events.VAMMPriceChange(
            self.immutableConfig.marketId, self.immutableConfig.maturityTimestamp, self.vars.tick, block.timestamp
        );

        emit Events.Swap(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            msg.sender,
            params.amountSpecified,
            params.sqrtPriceLimitX96,
            state.tokenDeltaCumulative,
            block.timestamp
        );

        return state.tokenDeltaCumulative;
    }

    function calculateGlobalTrackerValues(
        SwapState memory state,
        PositionBalances memory deltas
    )
        private
        pure
        returns (PositionBalances memory)
    {
        return PositionBalances({
            base: state.growthGlobalX128.base + FullMath.mulDivSigned(deltas.base, FixedPoint128.Q128, state.liquidity),
            quote: state.growthGlobalX128.quote + FullMath.mulDivSigned(deltas.quote, FixedPoint128.Q128, state.liquidity),
            extraCashflow: state.growthGlobalX128.extraCashflow
                + FullMath.mulDivSigned(deltas.extraCashflow, FixedPoint128.Q128, state.liquidity)
        });
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
