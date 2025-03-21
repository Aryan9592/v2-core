/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { UnfilledBalances, OrderDirection, PVMRComponents } from "./DataTypes.sol";
import { Portfolio } from "../storage/Portfolio.sol";
import { Market } from "../storage/Market.sol";
import { IPool } from "../interfaces/IPool.sol";

import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { DecimalMath } from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import {
    mulUDxInt, divIntUD, mulUDxUint, mulSDxInt
} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

import { UD60x18, ud } from "@prb/math/UD60x18.sol";
import { SD59x18, sd, UNIT } from "@prb/math/SD59x18.sol";

import { SignedMath } from "oz/utils/math/SignedMath.sol";

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
        int256 baseBalance,
        UD60x18 exposureFactor
    )
        internal
        view
        returns (UD60x18)
    {
        // todo: consider passing quote token and twap lookback as arguments to this helper

        Market.Data storage market = Market.exists(marketId);

        int256 annualizedExposureWad = DecimalMath.changeDecimals(
            baseToAnnualizedExposure(-baseBalance, maturityTimestamp, exposureFactor),
            IERC20(market.quoteToken).decimals(),
            DecimalMath.WAD_DECIMALS
        );

        OrderDirection orderDirection;
        if (annualizedExposureWad > 0) {
            orderDirection = OrderDirection.Long;
        } else if (annualizedExposureWad < 0) {
            orderDirection = OrderDirection.Short;
        } else {
            orderDirection = OrderDirection.Zero;
        }

        return IPool(poolAddress).getAdjustedTwap(
            marketId,
            maturityTimestamp,
            orderDirection,
            market.marketConfig.twapLookbackWindow,
            getPercentualSlippage(marketId, maturityTimestamp, annualizedExposureWad)
        );
    }

    function computeUnrealizedPnL(
        uint32 maturityTimestamp,
        int256 base,
        int256 quote,
        UD60x18 unwindPrice,
        UD60x18 exposureFactor
    )
        internal
        view
        returns (int256 uPnL)
    {
        uint32 timestamp = Time.blockTimestampTruncated();

        if ((base == 0 && quote == 0) || maturityTimestamp <= timestamp) {
            return 0;
        }

        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(timestamp, maturityTimestamp);

        int256 unwindQuote = computeQuoteDelta(-base, unwindPrice, exposureFactor);
        uPnL = mulUDxInt(timeDeltaAnnualized, quote + unwindQuote);
    }

    function computeUnwindPriceForGivenUPnL(
        uint32 maturityTimestamp,
        int256 baseBalance,
        int256 quoteBalance,
        int256 uPnL,
        UD60x18 exposureFactor
    )
        internal
        view
        returns (SD59x18 unwindPrice)
    {
        SD59x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp).intoSD59x18();

        int256 exposure = mulUDxInt(exposureFactor, baseBalance);
        SD59x18 price = sd(uPnL - quoteBalance).div(sd(exposure)).sub(UNIT).div(timeDeltaAnnualized);

        return price;
    }

    function baseToAnnualizedExposure(
        int256 baseAmount,
        uint32 maturityTimestamp,
        UD60x18 exposureFactor
    )
        internal
        view
        returns (int256 annualizedExposure)
    {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);
        annualizedExposure = mulUDxInt(timeDeltaAnnualized.mul(exposureFactor), baseAmount);
    }

    function getExposureComponents(
        int256 base,
        UD60x18 exposureFactor,
        uint256 tenorInSeconds,
        uint256 maturityTimestamp
    )
        internal
        view
        returns (int256[] memory exposureComponents)
    {
        exposureComponents = new int256[](2);

        if (base == 0 || maturityTimestamp <= block.timestamp) {
            return exposureComponents;
        }

        int256 notional = mulUDxInt(exposureFactor, base);
        uint256 timeToMaturityInSeconds = maturityTimestamp - block.timestamp;

        // short rate exposure
        {
            int256 num = tenorInSeconds.toInt() - timeToMaturityInSeconds.toInt();
            int256 den = tenorInSeconds.toInt() - SECONDS_IN_DAY.toInt();
            SD59x18 factor = sd(num).div(sd(den)).mul(Time.annualize(SECONDS_IN_DAY).intoSD59x18());

            exposureComponents[0] = mulSDxInt(factor, notional);
        }

        // swap rate exposure
        {
            int256 num = timeToMaturityInSeconds.toInt() - SECONDS_IN_DAY.toInt();
            int256 den = tenorInSeconds.toInt() - SECONDS_IN_DAY.toInt();
            SD59x18 factor = sd(num).div(sd(den)).mul(Time.annualize(tenorInSeconds).intoSD59x18());

            exposureComponents[1] = mulSDxInt(factor, notional);
        }
    }

    function getPVMRComponents(
        UnfilledBalances memory unfilledBalances,
        uint32 maturityTimestamp,
        UD60x18 exposureFactor,
        UD60x18 diagonalRiskParameter
    )
        internal
        view
        returns (PVMRComponents memory pvmrComponents)
    {
        int256 unrealizedPnLShort = computeUnrealizedPnL(
            maturityTimestamp,
            -unfilledBalances.baseShort.toInt(),
            unfilledBalances.quoteShort.toInt(),
            unfilledBalances.averagePriceShort.sub(diagonalRiskParameter),
            exposureFactor
        );

        pvmrComponents.short = unrealizedPnLShort > 0 ? 0 : (-unrealizedPnLShort).toUint();

        int256 unrealizedPnLLong = computeUnrealizedPnL(
            maturityTimestamp,
            unfilledBalances.baseLong.toInt(),
            -unfilledBalances.quoteLong.toInt(),
            unfilledBalances.averagePriceLong.add(diagonalRiskParameter),
            exposureFactor
        );

        pvmrComponents.long = unrealizedPnLLong > 0 ? 0 : (-unrealizedPnLLong).toUint();

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

    // todo: @AB this check is not used anywhere
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

    function computeQuoteDelta(
        int256 baseDelta,
        UD60x18 markPrice,
        UD60x18 exposureFactor
    )
        internal
        pure
        returns (int256)
    {
        int256 exposure = mulUDxInt(exposureFactor, baseDelta);
        return mulUDxInt(markPrice, -exposure);
    }
}
