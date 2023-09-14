/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {Portfolio} from "../storage/Portfolio.sol";
import {Market} from "../storage/Market.sol";
import {IPool} from "../interfaces/IPool.sol";

import {Account} from "@voltz-protocol/core/src/storage/Account.sol";

import { mulUDxInt, divIntUD, mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import {Time} from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";
import {DecimalMath} from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import { UD60x18, UNIT, convert as convert_ud } from "@prb/math/UD60x18.sol";

/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library ExposureHelpers {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using Market for Market.Data;
    using Portfolio for Portfolio.Data;

    error PositionExceedsSizeLimit(uint256 positionSizeLimit, uint256 positionSize);
    error OpenInterestLimitExceeded(uint256 limit, uint256 openInterest);

    struct PoolExposureState {
        uint128 marketId;
        uint32 maturityTimestamp;
        UD60x18 annualizedExposureFactor;

        int256 baseBalance;
        int256 quoteBalance;
        int256 accruedInterest;

        int256 baseBalancePool;
        int256 quoteBalancePool;
        int256 accruedInterestPool;

        uint256 unfilledBaseLong;
        uint256 unfilledQuoteLong;
        uint256 unfilledBaseShort;
        uint256 unfilledQuoteShort;
    }

    function computeUnrealizedLoss(
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress,
        int256 baseBalance,
        int256 quoteBalance
    ) internal view returns (uint256 unrealizedLoss) {
        int256 unwindQuote = computeUnwindQuote(marketId, maturityTimestamp, poolAddress, baseBalance);
        int256 unrealizedPnL = quoteBalance + unwindQuote;

        if (unrealizedPnL < 0) {
            unrealizedLoss = uint256(-unrealizedPnL);
        }
    }

    function computeUnwindQuote(
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress,
        int256 baseAmount
    )
        internal
        view
        returns (int256 unwindQuote)
    {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);

        Market.Data storage market = Market.exists(marketId);
        UD60x18 currentLiquidityIndex = market.getRateIndexCurrent();

        int256 orderSizeWad = DecimalMath.changeDecimals(
            -baseAmount, 
            IERC20(market.quoteToken).decimals(),
            DecimalMath.WAD_DECIMALS
        );
        UD60x18 twap = IPool(poolAddress).getAdjustedDatedIRSTwap(
            marketId, 
            maturityTimestamp, 
            orderSizeWad, 
            market.marketConfig.twapLookbackWindow
        );

        unwindQuote = mulUDxInt(twap.mul(timeDeltaAnnualized).add(UNIT), mulUDxInt(currentLiquidityIndex, baseAmount));
    }

    function exposureFactor(uint128 marketId) internal view returns (UD60x18 factor) {
        bytes32 marketType = Market.exists(marketId).marketType;
        if (marketType == Market.LINEAR_MARKET) {
            return UNIT;
        } else if (marketType == Market.COMPOUNDING_MARKET) {
            UD60x18 currentLiquidityIndex = Market.exists(marketId).getRateIndexCurrent();
            return currentLiquidityIndex;
        }

        revert Market.UnsupportedMarketType(marketType);
    }

    /**
     * @dev in context of interest rate swaps, base refers to scaled variable tokens (e.g. scaled virtual aUSDC)
     * @dev in order to derive the annualized exposure of base tokens in quote terms (i.e. USDC), we need to
     * first calculate the (non-annualized) exposure by multiplying the baseAmount by the current liquidity index of the
     * underlying rate oracle (e.g. aUSDC lend rate oracle)
     */
    function annualizedExposureFactor(uint128 marketId, uint32 maturityTimestamp) internal view returns (UD60x18) {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);
        UD60x18 factor = exposureFactor(marketId);

        return timeDeltaAnnualized.mul(factor);
    }

    function baseToAnnualizedExposure(
        int256[] memory baseAmounts,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (int256[] memory annualizedExposures)
    {
        annualizedExposures = new int256[](baseAmounts.length);
        UD60x18 factor = annualizedExposureFactor(marketId, maturityTimestamp);

        for (uint256 i = 0; i < baseAmounts.length; i++) {
            annualizedExposures[i] = mulUDxInt(factor, baseAmounts[i]);
        }
    }

    function baseToExposure(
        int256[] memory baseAmounts,
        uint128 marketId
    )
        internal
        view
        returns (int256[] memory exposures)
    {
        exposures = new int256[](baseAmounts.length);
        UD60x18 factor = exposureFactor(marketId);

        for (uint256 i = 0; i < baseAmounts.length; i++) {
            exposures[i] = mulUDxInt(factor, baseAmounts[i]);
        }
    }

    function getUnfilledExposureLowerInPool(
        PoolExposureState memory poolState,
        address poolAddress
    ) internal view returns (Account.MarketExposure memory) {
        uint256 unrealizedLossLower = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool + poolState.unfilledQuoteShort.toInt()
        );

        return Account.MarketExposure({
            annualizedNotional: mulUDxInt(
                poolState.annualizedExposureFactor, 
                poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt()
            ),
            pnlComponents: Account.PnLComponents({
                accruedCashflows: 0,     // todo: during tokenization implementation
                lockedPnL: 0,            // todo: during tokenization implementation
                unrealizedPnL: -unrealizedLossLower.toInt()
            })
        });
    }

    function getUnfilledExposureUpperInPool(
        PoolExposureState memory poolState,
        address poolAddress
    ) internal view returns (Account.MarketExposure memory) {
        uint256 unrealizedLossUpper = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool - poolState.unfilledQuoteLong.toInt()
        );

        return Account.MarketExposure({
            annualizedNotional: mulUDxInt(
                poolState.annualizedExposureFactor,
                poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt()
            ),
            pnlComponents: Account.PnLComponents({
                accruedCashflows: 0,     // todo: during tokenization implementation
                lockedPnL: 0,            // todo: during tokenization implementation
                unrealizedPnL: -unrealizedLossUpper.toInt()
            })
        });
    }

    function checkPositionSizeLimit(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal view {
        Market.Data storage market = Market.exists(marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        Account.MakerMarketExposure memory exposure = 
            portfolio.getAccountExposuresPerMaturity(address(pool), maturityTimestamp);
        uint256 positionSize = SignedMath.abs(
            exposure.lower.annualizedNotional > exposure.upper.annualizedNotional ?
                exposure.lower.annualizedNotional :
                exposure.upper.annualizedNotional
        );

        uint256 upperLimit = market.marketConfig.positionSizeUpperLimit;
        if (positionSize > upperLimit) {
            revert PositionExceedsSizeLimit(upperLimit, positionSize);
        }
        uint256 lowerLimit = market.marketConfig.positionSizeLowerLimit;
        if (positionSize < lowerLimit) {
            revert PositionExceedsSizeLimit(lowerLimit, positionSize);
        }
    }

    function checkOpenInterestLimit(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 annualizedNotionalDelta
    ) internal {
        Market.Data storage market = Market.exists(marketId);

        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);

        // update the notional tracker
        int256 notionalDelta = divIntUD(annualizedNotionalDelta, timeDeltaAnnualized);
        if (notionalDelta > 0) {
            market.notionalTracker[maturityTimestamp] += notionalDelta.toUint();
        } else {
            market.notionalTracker[maturityTimestamp] -= (-notionalDelta).toUint();
        }
        

        // check upper limit of open interest
        if (annualizedNotionalDelta > 0) {
            uint256 totalNotional = market.notionalTracker[maturityTimestamp];
            uint256 currentOpenInterest = mulUDxUint(timeDeltaAnnualized, totalNotional);

            uint256 upperLimit = market.marketConfig.openInterestUpperLimit;
            if (currentOpenInterest > upperLimit) {
                revert OpenInterestLimitExceeded(upperLimit, currentOpenInterest);
            }
        }
    }

    function getMTMAccruedInterest(
        int256 baseBalance,
        int256 quoteBalance,
        uint256 fromTimestamp, 
        uint256 toTimestamp, 
        UD60x18 fromRateIndex, 
        UD60x18 toRateIndex
    ) internal pure returns (int256 accruedInterest) {
        UD60x18 annualizedTime = Time.timeDeltaAnnualized(uint32(fromTimestamp), uint32(toTimestamp));
        return 
            mulUDxInt(toRateIndex.sub(fromRateIndex), baseBalance) +
            mulUDxInt(annualizedTime.div(convert_ud(100)), quoteBalance);
    }
}
