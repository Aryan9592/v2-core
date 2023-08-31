// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "./LPPosition.sol";
import "./Oracle.sol";
import {PoolConfiguration} from "./PoolConfiguration.sol";

import "../libraries/vamm-utils/VammBase.sol";
import "../libraries/vamm-utils/VammTicks.sol";
import "../libraries/vamm-utils/SwapMath.sol";
import "../libraries/vamm-utils/VammConfiguration.sol";
import "../libraries/ticks/TickBitmap.sol";
import "../libraries/time/Time.sol";
import "../libraries/math/FixedAndVariableMath.sol";
import "../libraries/errors/VammCustomErrors.sol";

import { UD60x18, convert, ud } from "@prb/math/UD60x18.sol";

import {SafeCastU256, SafeCastI256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SafeCastU128 for uint128;
    using VammBase for bool;
    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Oracle for Oracle.Observation[65535];
    using LPPosition for LPPosition.Data;
    using DatedIrsVamm for Data;
    using VammTicks for Data;

    /// @dev Internal, frequently-updated state of the VAMM, which is compressed into one storage slot.
    struct Data {
        /// @dev vamm config set at initialization, can't be modified after creation
        VammConfiguration.Immutable immutableConfig;
        /// @dev configurable vamm config
        VammConfiguration.Mutable mutableConfig;
        /// @dev vamm state frequently-updated
        VammConfiguration.State vars;
        /// @dev Equivalent to getSqrtRatioAtTick(minTickAllowed)
        uint160 minSqrtRatioAllowed;
        /// @dev Equivalent to getSqrtRatioAtTick(maxTickAllowed)
        uint160 maxSqrtRatioAllowed;
    }

    struct SwapParams {
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap 
        ///     as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
        /// @dev Mark price used to compute dynamic price limits
        UD60x18 markPrice;
        /// @dev Fixed Mark Price Band applied to the mark price to compute the dynamic price limits
        UD60x18 markPriceBand;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) private pure returns (Data storage irsVamm) {
        if (id == 0) {
            revert VammCustomErrors.IRSVammNotFound(0);
        }
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function exists(uint256 id) internal view returns (Data storage irsVamm) {
        irsVamm = load(id);
        if (irsVamm.immutableConfig.maturityTimestamp == 0) {
            revert VammCustomErrors.IRSVammNotFound(id);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint32 maturityTimestamp) internal view returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = load(id);
        if (irsVamm.immutableConfig.maturityTimestamp == 0) {
            revert VammCustomErrors.MarketAndMaturityCombinaitonNotSupported(marketId, maturityTimestamp);
        }
    }

    /// @dev Mutually exclusive reentrancy protection into the pool to/from a method. This method also prevents entrance
    /// to a function before the pool is initialized. The reentrancy guard is required throughout the contract because
    /// we use balance checks to determine the payment status of interactions such as mint, swap and flash.
    modifier lock(Data storage self) {
        if (!self.vars.unlocked) {
            revert VammCustomErrors.CanOnlyTradeIfUnlocked();
        }
        self.vars.unlocked = false;
        _;
        if (self.vars.unlocked) {
            revert VammCustomErrors.CanOnlyUnlockIfLocked();
        }
        self.vars.unlocked = true;
    }

    /**
     * @notice Executes a dated maker order that provides liquidity to (or removes liquidty from) this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function executeDatedMakerOrder(
        Data storage self,
        uint128 accountId,
        uint128 marketId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
    internal
    { 
        uint32 maturityTimestamp = self.immutableConfig.maturityTimestamp;
        Time.checkCurrentTimestampMaturityTimestampDelta(maturityTimestamp);
        
        (LPPosition.Data storage position, bool newlyCreated) = 
            LPPosition.ensurePositionOpened(accountId, marketId, maturityTimestamp, tickLower, tickUpper);
        if (newlyCreated) {
            uint256 positionsPerAccountLimit = PoolConfiguration.load().makerPositionsPerAccountLimit;
            if (self.vars.positionsInAccount[accountId].length >= positionsPerAccountLimit) {
                revert VammCustomErrors.TooManyLpPositions(accountId);
            }
            self.vars.positionsInAccount[accountId].push(
                LPPosition.getPositionId(accountId, marketId, maturityTimestamp, tickLower, tickUpper)
            );
        }

        // this also checks if the position has enough liquidity to burn
        self.updatePositionTokenBalances( 
            position,
            tickLower,
            tickUpper,
            true
        );

        position.updateLiquidity(liquidityDelta);

        _updateLiquidity(self, tickLower, tickUpper, liquidityDelta);

        emit VammBase.LiquidityChange(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            msg.sender,
            accountId,
            tickLower,
            tickUpper,
            liquidityDelta,
            block.timestamp
        );
    }

    /// @notice update position token balances and account for fees
    /// @dev if the _liquidity of the position supplied to this function is >0 then we
    /// @dev 1. retrieve the fixed, variable and fee Growth variables from the vamm by 
    ///     invoking the computeGrowthInside function of the VAMM
    /// @dev 2. calculate the deltas that need to be applied to the position's fixed and variable token balances 
    ///     by taking into account trades that took place in the VAMM since the last mint/poke/burn that invoked this function
    /// @dev 3. update the fixed and variable token balances and the margin of the position to account for deltas (outlined above) 
    ///     and fees generated by the active liquidity supplied by the position
    /// @dev 4. additionally, we need to update the last growth inside variables in the Position.Info struct 
    ///     so that we take a note that we've accounted for the changes up until this point
    /// @dev if _liquidity of the position supplied to this function is zero, 
    ///     then we need to check if isMintBurn is set to true (if it is set to true) then we know this function was called post a mint/burn event,
    /// @dev meaning we still need to correctly update the last fixed, variable and fee growth variables in the Position.Info struct
    function updatePositionTokenBalances(
        Data storage self,
        LPPosition.Data storage position,
        int24 tickLower,
        int24 tickUpper,
        bool isMintBurn
    ) internal {
        if (position.liquidity > 0) {
            (
                int256 _quoteTokenGrowthInsideX128,
                int256 _baseTokenGrowthInsideX128
            ) = self.computeGrowthInside(tickLower, tickUpper);
            (int256 _quoteTokenDelta, int256 _baseTokenDelta) = position
                .calculateFixedAndVariableDelta(
                    _quoteTokenGrowthInsideX128,
                    _baseTokenGrowthInsideX128
                );
            
            position.updateTrackers(
                _quoteTokenGrowthInsideX128,
                _baseTokenGrowthInsideX128,
                _quoteTokenDelta,
                _baseTokenDelta
            );
        } else {
            if (isMintBurn) {
                (
                    int256 _quoteTokenGrowthInsideX128,
                    int256 _baseTokenGrowthInsideX128
                ) = self.computeGrowthInside(tickLower, tickUpper);
                position.updateTrackers(
                    _quoteTokenGrowthInsideX128,
                    _baseTokenGrowthInsideX128,
                    0,
                    0
                );
            }
        }
    }

    /// @dev Private but labelled internal for testability. Consumers of the library should use `executeDatedMakerOrder()`.
    /// Mints (`liquidityDelta > 0`) or burns (`liquidityDelta < 0`) 
    ///     `liquidityDelta` liquidity for the specified `accountId`, uniformly between the specified ticks.
    function _updateLiquidity(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    ) internal
      lock(self)
    {
        Time.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        if (liquidityDelta > 0) {
            self.checkTicksInAllowedRange(tickLower, tickUpper);
        } else {
            VammTicks.checkTicksLimits(tickLower, tickUpper);
        }
        
        bool flippedLower;
        bool flippedUpper;

        /// @dev update the ticks if necessary
        if (liquidityDelta != 0) {
            (flippedLower, flippedUpper) = self.flipTicks(
                tickLower,
                tickUpper,
                liquidityDelta
            );
        }

        // clear any tick data that is no longer needed
        if (liquidityDelta < 0) {
            if (flippedLower) {
                self.vars._ticks.clear(tickLower);
            }
            if (flippedUpper) {
                self.vars._ticks.clear(tickUpper);
            }
        }

        if (liquidityDelta != 0) {
            if (
                (self.vars.tick >= tickLower) && (self.vars.tick < tickUpper)
            ) {
                // current tick is inside the passed range
                uint128 liquidityBefore = self.vars.liquidity; // SLOAD for gas optimization

                self.vars.liquidity = LiquidityMath.addDelta(
                    liquidityBefore,
                    liquidityDelta
                );
            }
        }
    }

    /// @dev Stores fixed values required in each swap step 
    struct SwapFixedValues {
        uint256 secondsTillMaturity;
        VammTicks.TickLimits tickLimits;
        UD60x18 liquidityIndex;
    }

    /// @dev amountSpecified The amount of the swap in base tokens, 
    ///     which implicitly configures the swap as exact input (positive), or exact output (negative)
    /// @dev sqrtPriceLimitX96 The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
    function vammSwap(
        Data storage self,
        SwapParams memory params
    )
        internal
        lock(self)
        returns (int256 quoteTokenDelta, int256 baseTokenDelta)
    {
        Time.checkCurrentTimestampMaturityTimestampDelta(self.immutableConfig.maturityTimestamp);

        SwapFixedValues memory swapFixedValues = SwapFixedValues({
            secondsTillMaturity: self.immutableConfig.maturityTimestamp - block.timestamp,
            tickLimits: self.getCurrentTickLimits(params.markPrice, params.markPriceBand),
            liquidityIndex: PoolConfiguration.getRateOracle(self.immutableConfig.marketId).getCurrentIndex()
        });

        self.checksBeforeSwap(
            params.amountSpecified, 
            params.sqrtPriceLimitX96, 
            params.amountSpecified > 0,
            swapFixedValues.tickLimits.minSqrtRatio,
            swapFixedValues.tickLimits.maxSqrtRatio
        );

        uint128 liquidityStart = self.vars.liquidity;

        VammBase.SwapState memory state = VammBase.SwapState({
            amountSpecifiedRemaining: params.amountSpecified, // base ramaining
            sqrtPriceX96: self.vars.sqrtPriceX96,
            tick: self.vars.tick,
            liquidity: liquidityStart,
            trackerQuoteTokenGrowthGlobalX128: self.vars.trackerQuoteTokenGrowthGlobalX128,
            trackerBaseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128,
            quoteTokenDeltaCumulative: 0, // for Trader (user invoking the swap)
            baseTokenDeltaCumulative: 0 // for Trader (user invoking the swap)
        });

        // continue swapping as long as we haven't used the entire input/output and haven't 
        //     reached the price (implied fixed rate) limit
        while (
            state.amountSpecifiedRemaining != 0 &&
            state.sqrtPriceX96 != params.sqrtPriceLimitX96
        ) {
            VammBase.StepComputations memory step;

            ///// GET NEXT TICK /////

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            /// @dev if isFT (fixed taker) (moving right to left), 
            ///     the nextInitializedTick should be more than or equal to the current tick
            /// @dev if !isFT (variable taker) (moving left to right), 
            ///     the nextInitializedTick should be less than or equal to the current tick
            /// add a test for the statement that checks for the above two conditions
            (step.tickNext, step.initialized) = self.vars._tickBitmap
                .nextInitializedTickWithinOneWord(state.tick, self.immutableConfig._tickSpacing, !(params.amountSpecified > 0));

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
                step.unbalancedQuoteTokenDelta = -step.amountOut.toInt();
            } else {
                // LP is a Fixed Taker
                step.baseTokenDelta = -step.amountOut.toInt();
                step.unbalancedQuoteTokenDelta = step.amountIn.toInt(); // this is positive
            }

            ///// UPDATE TRACKERS /////
            state.amountSpecifiedRemaining -= step.baseTokenDelta;
            if (state.liquidity > 0) {
                step.quoteTokenDelta = VammBase.calculateQuoteTokenDelta(
                    step.unbalancedQuoteTokenDelta,
                    step.baseTokenDelta,
                    FixedAndVariableMath.accrualFact(swapFixedValues.secondsTillMaturity),
                    swapFixedValues.liquidityIndex,
                    self.mutableConfig.spread
                );

                (
                    state.trackerQuoteTokenGrowthGlobalX128,
                    state.trackerBaseTokenGrowthGlobalX128
                ) = VammBase.calculateGlobalTrackerValues(
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
                    int128 liquidityNet = self.vars._ticks.cross(
                        step.tickNext,
                        state.trackerQuoteTokenGrowthGlobalX128,
                        state.trackerBaseTokenGrowthGlobalX128
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

        // update liquidity if it changed
        if (liquidityStart != state.liquidity) self.vars.liquidity = state.liquidity;

        self.vars.trackerBaseTokenGrowthGlobalX128 = state.trackerBaseTokenGrowthGlobalX128;
        self.vars.trackerQuoteTokenGrowthGlobalX128 = state.trackerQuoteTokenGrowthGlobalX128;

        emit VammBase.VAMMPriceChange(
            self.immutableConfig.marketId,
            self.immutableConfig.maturityTimestamp,
            self.vars.tick,
            block.timestamp
        );

        emit VammBase.Swap(
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

    /// @notice For a given LP account, how much liquidity is available to trade in each direction.
    /// @param accountId The LP account. All positions within the account will be considered.
    /// @return unfilledBaseLong The base tokens available for a trader to take 
    ///     a long position against this LP (which will then become a short position for the LP) 
    /// @return unfilledBaseShort The base tokens available for a trader to take 
    ///      a short position against this LP (which will then become a long position for the LP) 
    function getAccountUnfilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort
        )
    {
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;
        if (numPositions != 0) {
            for (uint256 i = 0; i < numPositions; i++) {
                // Get how liquidity is currently arranged. In particular, 
                // how much of the liquidity is available to traders in each direction?
                (
                    uint256 unfilledLongBase,
                    uint256 unfilledShortBase,
                    uint256 unfilledLongQuote,
                    uint256 unfilledShortQuote
                ) = 
                    self._getUnfilledBalancesFromPosition(
                        self.vars.positionsInAccount[accountId][i]
                    );
                unfilledBaseLong += unfilledLongBase;
                unfilledBaseShort += unfilledShortBase;
                unfilledQuoteLong += unfilledLongQuote;
                unfilledQuoteShort += unfilledShortQuote;
            }
        }
    }

    function _getUnfilledBalancesFromPosition(
        Data storage self,
        uint128 positionId
    )
        internal
        view
        returns ( uint256, uint256, uint256, uint256 ) {
        LPPosition.Data storage position = LPPosition.exists(positionId);
        (
            uint256 unfilledShortBase,
            uint256 unfilledLongBase,
            uint256 unfilledShortQuote,
            uint256 unfilledLongQuote
        ) = _getUnfilledBaseTokenValues(
            self,
            position.tickLower,
            position.tickUpper,
            position.liquidity
        );

        return ( unfilledLongBase, unfilledShortBase, unfilledLongQuote, unfilledShortQuote);
    }

    /// @dev For a given LP posiiton, how much of it is already traded and what are base and 
    /// quote tokens representing those exiting trades?
    function getAccountFilledBalances(
        Data storage self,
        uint128 accountId
    )
        internal
        view
        returns (int256 baseBalancePool, int256 quoteBalancePool) {
        
        uint256 numPositions = self.vars.positionsInAccount[accountId].length;

        for (uint256 i = 0; i < numPositions; i++) {
            LPPosition.Data storage position = LPPosition.exists(self.vars.positionsInAccount[accountId][i]);
            (int256 trackerQuoteTokenGlobalGrowth, int256 trackerBaseTokenGlobalGrowth) = 
                growthBetweenTicks(self, position.tickLower, position.tickUpper);
            (int256 trackerQuoteTokenAccumulated, int256 trackerBaseTokenAccumulated) = 
                position.getUpdatedPositionBalances(trackerQuoteTokenGlobalGrowth, trackerBaseTokenGlobalGrowth); 

            baseBalancePool += trackerBaseTokenAccumulated;
            quoteBalancePool += trackerQuoteTokenAccumulated;
        }

    }

    /// @dev Private but labelled internal for testability.
    ///
    /// Gets the number of "unfilled" (still available as liquidity) base tokens within the specified tick range,
    /// looking both left and right of the current tick.
    function _getUnfilledBaseTokenValues(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidityPerTick
    ) internal view returns(
        uint256 unfilledBaseTokensLeft,
        uint256 unfilledBaseTokensRight,
        uint256 unfilledQuoteTokensLeft,
        uint256 unfilledQuoteTokensRight
    ) {
        if (tickLower == tickUpper) {
            return (0, 0, 0, 0);
        }

        uint256 secondsTillMaturity = self.immutableConfig.maturityTimestamp - block.timestamp;
        // Compute unfilled tokens in our range and to the left of the current tick
        (unfilledBaseTokensLeft, unfilledQuoteTokensLeft) = self._getUnfilledBalancesLeft(
            tickLower < self.vars.tick ? tickLower : self.vars.tick, // min(tickLower, currentTick)
            tickUpper < self.vars.tick ? tickUpper : self.vars.tick,  // min(tickUpper, currentTick)
            liquidityPerTick.toInt(),
            secondsTillMaturity
        );

        // Compute unfilled tokens in our range and to the right of the current tick
        (unfilledBaseTokensRight, unfilledQuoteTokensRight) = self._getUnfilledBalancesRight(
            tickLower > self.vars.tick ? tickLower : self.vars.tick, // max(tickLower, currentTick)
            tickUpper > self.vars.tick ? tickUpper : self.vars.tick,  // max(tickUpper, currentTick)
            liquidityPerTick.toInt(),
            secondsTillMaturity
        );
    }

    function _getUnfilledBalancesLeft(
        Data storage self,
        int24 leftLowerTick,
        int24 leftUpperTick,
        int128 liquidityPerTick,
        uint256 secondsTillMaturity
    ) 
        internal view
        returns (uint256, uint256) {
        
        uint256 unfilledBaseTokensLeft = baseBetweenTicks(
            leftLowerTick,
            leftUpperTick,
            liquidityPerTick
        ).toUint();

        if ( unfilledBaseTokensLeft == 0 ) {
            return (0, 0);
        }

        // unfilledBaseTokensLeft is negative
        int256 unbalancedQuoteTokensLeft = unbalancedQuoteBetweenTicks(
            leftLowerTick,
            leftUpperTick,
            -(unfilledBaseTokensLeft).toInt()
        );
        // note calculateQuoteTokenDelta considers spread in advantage (for LPs)
        uint256 unfilledQuoteTokensLeft = VammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokensLeft,
            -(unfilledBaseTokensLeft).toInt(),
            FixedAndVariableMath.accrualFact(secondsTillMaturity),
            PoolConfiguration.getRateOracle(self.immutableConfig.marketId).getCurrentIndex(),
            self.mutableConfig.spread
        ).toUint();

        return (unfilledBaseTokensLeft, unfilledQuoteTokensLeft);
    }

    function _getUnfilledBalancesRight(
        Data storage self,
        int24 rightLowerTick,
        int24 rightUpperTick,
        int128 liquidityPerTick,
        uint256 secondsTillMaturity
    ) 
        internal view
        returns (uint256, uint256){
        
        uint256 unfilledBaseTokensRight = baseBetweenTicks(
            rightLowerTick,
            rightUpperTick,
            liquidityPerTick
        ).toUint();

        if ( unfilledBaseTokensRight == 0 ) {
            return (0, 0);
        }

        // unbalancedQuoteTokensRight is positive
        int256 unbalancedQuoteTokensRight = unbalancedQuoteBetweenTicks(
            rightLowerTick,
            rightUpperTick,
            unfilledBaseTokensRight.toInt()
        );

        // unfilledQuoteTokensRight is negative
        uint256 unfilledQuoteTokensRight = (-VammBase.calculateQuoteTokenDelta(
            unbalancedQuoteTokensRight,
            unfilledBaseTokensRight.toInt(),
            FixedAndVariableMath.accrualFact(secondsTillMaturity),
            PoolConfiguration
                .getRateOracle(self.immutableConfig.marketId)
                .getCurrentIndex(),
            self.mutableConfig.spread
        )).toUint();

        return (unfilledBaseTokensRight, unfilledQuoteTokensRight);
    }

    function growthBetweenTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    ) internal view returns (
        int256 trackerQuoteTokenGrowthBetween,
        int256 trackerBaseTokenGrowthBetween
    )
    {
        VammTicks.checkTicksLimits(tickLower, tickUpper);

        int256 trackerQuoteTokenBelowLowerTick;
        int256 trackerBaseTokenBelowLowerTick;

        if (tickLower <= self.vars.tick) {
            trackerQuoteTokenBelowLowerTick = self.vars._ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenBelowLowerTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenBelowLowerTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickLower].trackerBaseTokenGrowthOutsideX128;
        }

        int256 trackerQuoteTokenAboveUpperTick;
        int256 trackerBaseTokenAboveUpperTick;

        if (tickUpper > self.vars.tick) {
            trackerQuoteTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        } else {
            trackerQuoteTokenAboveUpperTick = self.vars.trackerQuoteTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerQuoteTokenGrowthOutsideX128;
            trackerBaseTokenAboveUpperTick = self.vars.trackerBaseTokenGrowthGlobalX128 -
                self.vars._ticks[tickUpper].trackerBaseTokenGrowthOutsideX128;
        }

        trackerQuoteTokenGrowthBetween = 
            self.vars.trackerQuoteTokenGrowthGlobalX128 - trackerQuoteTokenBelowLowerTick - trackerQuoteTokenAboveUpperTick;
        trackerBaseTokenGrowthBetween = 
            self.vars.trackerBaseTokenGrowthGlobalX128 - trackerBaseTokenBelowLowerTick - trackerBaseTokenAboveUpperTick;

    }

    function computeGrowthInside(
        Data storage self,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        view
        returns (int256 quoteTokenGrowthInsideX128, int256 baseTokenGrowthInsideX128)
    {

        VammTicks.checkTicksLimits(tickLower, tickUpper);

        baseTokenGrowthInsideX128 = self.vars._ticks.getBaseTokenGrowthInside(
            Tick.BaseTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                baseTokenGrowthGlobalX128: self.vars.trackerBaseTokenGrowthGlobalX128
            })
        );

        quoteTokenGrowthInsideX128 = self.vars._ticks.getQuoteTokenGrowthInside(
            Tick.QuoteTokenGrowthInsideParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                tickCurrent: self.vars.tick,
                quoteTokenGrowthGlobalX128: self.vars.trackerQuoteTokenGrowthGlobalX128
            })
        );

    }

    function flipTicks(
        Data storage self,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        internal
        returns (
            bool flippedLower,
            bool flippedUpper
        )
    {
        /// @dev isUpper = false
        flippedLower = self.vars._ticks.update(
            tickLower,
            self.vars.tick,
            liquidityDelta,
            self.vars.trackerQuoteTokenGrowthGlobalX128,
            self.vars.trackerBaseTokenGrowthGlobalX128,
            false,
            self.immutableConfig._maxLiquidityPerTick
        );

        /// @dev isUpper = true
        flippedUpper = self.vars._ticks.update(
            tickUpper,
            self.vars.tick,
            liquidityDelta,
            self.vars.trackerQuoteTokenGrowthGlobalX128,
            self.vars.trackerBaseTokenGrowthGlobalX128,
            true,
            self.immutableConfig._maxLiquidityPerTick
        );

        if (flippedLower) {
            self.vars._tickBitmap.flipTick(tickLower, self.immutableConfig._tickSpacing);
        }

        if (flippedUpper) {
            self.vars._tickBitmap.flipTick(tickUpper, self.immutableConfig._tickSpacing);
        }
    }

    /// @dev Computes the agregate amount of base between two ticks, given a tick range and the amount of liquidity per tick.
    /// The answer must be a valid `int256`. Reverts on overflow.
    function baseBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper,
        int128 _liquidityPerTick
    ) internal pure returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickLower);

        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickUpper);

        return VammBase.baseAmountFromLiquidity(_liquidityPerTick, sqrtRatioAX96, sqrtRatioBX96);
    }

    function unbalancedQuoteBetweenTicks(
        int24 _tickLower,
        int24 _tickUpper,
        int256 baseAmount
    ) internal pure returns(int256) {
        // get sqrt ratios
        uint160 sqrtRatioAX96 = TickMath.getSqrtRatioAtTick(_tickLower);

        uint160 sqrtRatioBX96 = TickMath.getSqrtRatioAtTick(_tickUpper);

        return VammBase.unbalancedQuoteAmountFromBase(baseAmount, sqrtRatioAX96, sqrtRatioBX96);
    }
}
