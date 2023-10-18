/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { Portfolio } from "../storage/Portfolio.sol";
import { Market } from "../storage/Market.sol";
import { IPool } from "../interfaces/IPool.sol";

import { Account } from "@voltz-protocol/core/src/storage/Account.sol";

import {
    mulUDxInt, divIntUD, mulUDxUint, mulSDxInt
} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { SignedMath } from "oz/utils/math/SignedMath.sol";
import { DecimalMath } from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import { UD60x18, UNIT as UNIT_ud, ZERO as ZERO_ud, ud } from "@prb/math/UD60x18.sol";
import { sd, SD59x18, UNIT as UNIT_sd } from "@prb/math/SD59x18.sol";
import { IRiskConfigurationModule } from "@voltz-protocol/core/src/interfaces/IRiskConfigurationModule.sol";
import "../storage/MarketManagerConfiguration.sol";
import { FilledBalances, UnfilledBalances, PositionBalances, RateOracleObservation } from "../libraries/DataTypes.sol";
import { TraderPosition } from "../libraries/TraderPosition.sol";

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

    uint256 internal constant SECONDS_IN_DAY = 86_400;

    function getPercentualSlippage(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 annualizedExposureWad
    )
        internal
        view
        returns (UD60x18)
    {
        Market.Data storage market = Market.exists(marketId);
        UD60x18 phi = market.marketMaturityConfigs[maturityTimestamp].phi;
        UD60x18 beta = market.marketMaturityConfigs[maturityTimestamp].beta;

        uint256 absAnnualizedExposureWad = SignedMath.abs(annualizedExposureWad);
        UD60x18 absAnnualizedExposure = ud(absAnnualizedExposureWad);

        // power operation is performed on signed values since annualizedAbsOrderSize can be < UNIT
        return phi.mul(absAnnualizedExposure.intoSD59x18().pow(beta.intoSD59x18()).intoUD60x18());
    }

    function computeTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress,
        int256 baseBalance
    )
        internal
        view
        returns (UD60x18)
    {
        // todo: consider passing quote token and twap lookback as arguments to this helper

        Market.Data storage market = Market.exists(marketId);

        int256 annualizedExposureWad = DecimalMath.changeDecimals(
            baseToAnnualizedExposure(-baseBalance, marketId, maturityTimestamp),
            IERC20(market.quoteToken).decimals(),
            DecimalMath.WAD_DECIMALS
        );

        IPool.OrderDirection orderDirection;
        if (annualizedExposureWad > 0) {
            orderDirection = IPool.OrderDirection.Long;
        } else if (annualizedExposureWad < 0) {
            orderDirection = IPool.OrderDirection.Short;
        } else {
            orderDirection = IPool.OrderDirection.Zero;
        }

        return IPool(poolAddress).getAdjustedTwap(
            marketId,
            maturityTimestamp,
            orderDirection,
            market.marketConfig.twapLookbackWindow,
            getPercentualSlippage(marketId, maturityTimestamp, annualizedExposureWad)
        );
    }

    function computeUnwindPnL(
        uint128 marketId,
        uint32 maturityTimestamp,
        PositionBalances memory balances,
        UD60x18 unwindPrice
    )
        internal
        view
        returns (int256)
    {
        PositionBalances memory unwindDeltas;

        unwindDeltas.base = -balances.base;
        unwindDeltas.quote = -mulUDxInt(unwindPrice, baseToExposure(unwindDeltas.base, marketId));
        unwindDeltas.extraCashflow = TraderPosition.computeCashflow(
            unwindDeltas.base, unwindDeltas.quote, Market.exists(marketId).getLatestRateIndex(maturityTimestamp)
        );

        int256 settlementPnL = TraderPosition.getAccruedInterest(
            PositionBalances({
                base: 0,
                quote: balances.quote + unwindDeltas.quote,
                extraCashflow: balances.extraCashflow + unwindDeltas.extraCashflow
            }),
            RateOracleObservation({ timestamp: maturityTimestamp, rateIndex: ZERO_ud })
        );

        return settlementPnL;
    }

    function computeUnwindPriceForGivenUPnL(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseBalance,
        int256 quoteBalance,
        int256 uPnL
    )
        internal
        view
        returns (SD59x18 unwindPrice)
    {
        SD59x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp).intoSD59x18();

        int256 exposure = baseToExposure(baseBalance, marketId);
        SD59x18 price = sd(uPnL - quoteBalance).div(sd(exposure)).sub(UNIT_sd).div(timeDeltaAnnualized);

        return price;
    }

    /**
     * @dev in context of interest rate swaps, base refers to scaled variable tokens (e.g. scaled virtual aUSDC)
     * @dev in order to derive the annualized exposure of base tokens in quote terms (i.e. USDC), we need to
     * first calculate the (non-annualized) exposure by multiplying the baseAmount by the current liquidity index of the
     * underlying rate oracle (e.g. aUSDC lend rate oracle)
     */
    function annualizedExposureFactor(uint128 marketId, uint32 maturityTimestamp) internal view returns (UD60x18) {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);
        UD60x18 factor = Market.exists(marketId).exposureFactor();

        return timeDeltaAnnualized.mul(factor);
    }

    function baseToAnnualizedExposure(
        int256 baseAmount,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (int256 annualizedExposure)
    {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);
        UD60x18 factor = Market.exists(marketId).exposureFactor();
        UD60x18 annualizedFactor = timeDeltaAnnualized.mul(factor);

        annualizedExposure = mulUDxInt(annualizedFactor, baseAmount);
    }

    function baseToExposure(int256 baseAmount, uint128 marketId) internal view returns (int256 exposure) {
        UD60x18 factor = Market.exists(marketId).exposureFactor();
        exposure = mulUDxInt(factor, baseAmount);
    }

    function decoupleExposures(
        int256 notional,
        uint256 tenorInSeconds,
        uint256 timeToMaturityInSeconds
    )
        private
        view
        returns (int256 shortRateExposure, int256 swapRateExposure)
    {
        // todo: division by zero checks, etc

        // short rate exposure
        int256 numSR = (tenorInSeconds - timeToMaturityInSeconds).toInt();
        int256 denSR = (tenorInSeconds - SECONDS_IN_DAY).toInt();
        SD59x18 notionalToExposureFactorSR = sd(numSR).div(sd(denSR)).mul(Time.annualize(SECONDS_IN_DAY).intoSD59x18());
        shortRateExposure = mulSDxInt(notionalToExposureFactorSR, notional);

        // swap rate exposure
        int256 numSWR = (timeToMaturityInSeconds - SECONDS_IN_DAY).toInt();
        int256 denSWR = (tenorInSeconds - SECONDS_IN_DAY).toInt();
        SD59x18 notionalToExposureFactorSWR =
            sd(numSWR).div(sd(denSWR)).mul(Time.annualize(tenorInSeconds).intoSD59x18());
        swapRateExposure = mulSDxInt(notionalToExposureFactorSWR, notional);

        return (shortRateExposure, swapRateExposure);
    }

    function getFilledExposures(
        int256 filledBase,
        UD60x18 exposureFactor,
        uint32 maturityTimestamp,
        uint256 tenorInSeconds
    )
        internal
        view
        returns (int256 shortRateFilledExposure, int256 swapRateFilledExposure)
    {
        int256 filledNotional = mulUDxInt(exposureFactor, filledBase);

        uint256 timeToMaturityInSeconds = uint256(maturityTimestamp) - block.timestamp;

        (shortRateFilledExposure, swapRateFilledExposure) =
            decoupleExposures(filledNotional, tenorInSeconds, timeToMaturityInSeconds);

        return (shortRateFilledExposure, swapRateFilledExposure);
    }

    function getUnfilledExposureComponents(
        uint256 unfilledBaseLong,
        uint256 unfilledBaseShort,
        UD60x18 exposureFactor,
        uint32 maturityTimestamp,
        uint256 tenorInSeconds
    )
        internal
        view
        returns (Account.UnfilledExposureComponents[] memory unfilledExposureComponents)
    {
        // first entry is for short rate and second is for swap rate
        unfilledExposureComponents = new Account.UnfilledExposureComponents[](2);
        uint256 timeToMaturityInSeconds = uint256(maturityTimestamp) - block.timestamp;

        if (unfilledBaseLong != 0) {
            uint256 unfilledNotionalLong = mulUDxUint(exposureFactor, unfilledBaseLong);

            (int256 unfilledExposureShortRate, int256 unfilledExposureSwapRate) =
                decoupleExposures(unfilledNotionalLong.toInt(), tenorInSeconds, timeToMaturityInSeconds);

            (unfilledExposureComponents[0].unfilledExposureLong, unfilledExposureComponents[1].unfilledExposureLong) =
                (unfilledExposureShortRate.toUint(), unfilledExposureSwapRate.toUint());
        }

        if (unfilledBaseShort != 0) {
            uint256 unfilledNotionalShort = mulUDxUint(exposureFactor, unfilledBaseShort);

            (int256 unfilledExposureShortRate, int256 unfilledExposureSwapRate) =
                decoupleExposures(unfilledNotionalShort.toInt(), tenorInSeconds, timeToMaturityInSeconds);

            (unfilledExposureComponents[0].unfilledExposureShort, unfilledExposureComponents[1].unfilledExposureShort) =
                (unfilledExposureShortRate.toUint(), unfilledExposureSwapRate.toUint());
        }

        return unfilledExposureComponents;
    }

    function computePVMRUnwindPrice(
        UD60x18 avgPrice,
        UD60x18 diagonalRiskParameter,
        bool isLong
    )
        private
        view
        returns (UD60x18 pvmrUnwindPrice)
    {
        // todo: note this doesn't take into account slippage & spread
        if (isLong) {
            avgPrice.add(diagonalRiskParameter);
        } else {
            avgPrice.sub(diagonalRiskParameter);
        }

        return pvmrUnwindPrice;
    }

    function getPVMRComponents(
        UnfilledBalances memory unfilledBalances,
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress,
        uint256 riskMatrixRowId
    )
        internal
        view
        returns (Account.PVMRComponents memory pvmrComponents)
    {
        UD60x18 diagonalRiskParameter;

        if ((unfilledBalances.baseShort != 0) || (unfilledBalances.baseLong != 0)) {
            address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();
            diagonalRiskParameter = IRiskConfigurationModule(coreProxy).getRiskMatrixParameterFromMM(
                marketId, riskMatrixRowId, riskMatrixRowId
            ).intoUD60x18();
        }

        if (unfilledBalances.baseShort != 0) {
            // todo: replace
            int256 unrealizedPnLShort = 0;

            // int256 unrealizedPnLShort = computeUnrealizedPnL(
            //     marketId,
            //     maturityTimestamp,
            //     -unfilledBalances.baseShort.toInt(),
            //     unfilledBalances.quoteShort.toInt(),
            //     computePVMRUnwindPrice(unfilledBalances.averagePriceShort, diagonalRiskParameter, false)
            // );

            pvmrComponents.pvmrShort = unrealizedPnLShort > 0 ? 0 : (-unrealizedPnLShort).toUint();
        }

        if (unfilledBalances.baseLong != 0) {
            // todo: replace
            int256 unrealizedPnLLong = 0;

            // int256 unrealizedPnLLong = computeUnrealizedPnL(
            //     marketId,
            //     maturityTimestamp,
            //     unfilledBalances.baseLong.toInt(),
            //     -unfilledBalances.quoteLong.toInt(),
            //     computePVMRUnwindPrice(unfilledBalances.averagePriceLong, diagonalRiskParameter, true)
            // );

            pvmrComponents.pvmrLong = unrealizedPnLLong > 0 ? 0 : (-unrealizedPnLLong).toUint();
        }

        return pvmrComponents;
    }

    function checkPositionSizeLimit(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) internal view {
        // todo: consider separate limit check for makers and takers
        // todo fix once exposures are finalized

        //        Market.Data storage market = Market.exists(marketId);
        //        IPool pool = IPool(market.marketConfig.poolAddress);
        //
        //        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        //
        //        Account.MarketExposure memory exposure =
        //            portfolio.getAccountExposuresPerMaturity(address(pool), maturityTimestamp);
        //
        //        uint256 positionSize = SignedMath.abs(
        //            exposure.exposureComponents.cfExposureShort > exposure.exposureComponents.cfExposureLong ?
        //                exposure.exposureComponents.cfExposureShort  :
        //                exposure.exposureComponents.cfExposureLong
        //        );
        //
        //        uint256 upperLimit = market.marketConfig.positionSizeUpperLimit;
        //        if (positionSize > upperLimit) {
        //            revert PositionExceedsSizeLimit(upperLimit, positionSize);
        //        }
        //        uint256 lowerLimit = market.marketConfig.positionSizeLowerLimit;
        //        if (positionSize < lowerLimit) {
        //            revert PositionExceedsSizeLimit(lowerLimit, positionSize);
        //        }
    }

    function checkOpenInterestLimit(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 annualizedNotionalDelta
    )
        internal
    {
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

    function computeQuoteDelta(int256 baseDelta, UD60x18 markPrice, uint128 marketId) internal view returns (int256) {
        int256 exposure = ExposureHelpers.baseToExposure(baseDelta, marketId);

        return mulUDxInt(markPrice, -exposure);
    }
}
