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

import { UD60x18, UNIT as UNIT_ud } from "@prb/math/UD60x18.sol";
import { sd, SD59x18, UNIT as UNIT_sd } from "@prb/math/SD59x18.sol";
import {IRiskConfigurationModule} from "@voltz-protocol/core/src/interfaces/IRiskConfigurationModule.sol";
import "../storage/MarketManagerConfiguration.sol";

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
        UD60x18 avgLongPrice;
        UD60x18 avgShortPrice;
    }

    struct AccruedInterestTrackers {
        int256 accruedInterest;
        uint256 lastMTMTimestamp;
        UD60x18 lastMTMRateIndex;
    }

    function computeTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress,
        int256 baseBalance
    ) private view returns (UD60x18) {

        Market.Data storage market = Market.exists(marketId);

        int256 orderSizeWad = DecimalMath.changeDecimals(
            -baseBalance,
            IERC20(market.quoteToken).decimals(),
            DecimalMath.WAD_DECIMALS
        );

        return IPool(poolAddress).getAdjustedDatedIRSTwap(
            marketId,
            maturityTimestamp,
            orderSizeWad,
            market.marketConfig.twapLookbackWindow
        );

    }

    function computeUnrealizedPnL(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseBalance,
        int256 quoteBalance,
        UD60x18 unwindPrice
    ) internal view returns (int256 unrealizedPnL) {
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);

        int256 exposure = baseToExposure(baseBalance, marketId);
        int256 unwindQuote = mulUDxInt(unwindPrice.mul(timeDeltaAnnualized).add(UNIT_ud), exposure);

        return quoteBalance + unwindQuote;
    }

    function computeUnwindPriceForGivenUPnL(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseBalance,
        int256 quoteBalance,
        int256 uPnL
    ) internal view returns (SD59x18 unwindPrice) {
        SD59x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp).intoSD59x18();

        int256 exposure = baseToExposure(baseBalance, marketId);
        SD59x18 price = sd(uPnL - quoteBalance).div(sd(exposure)).sub(UNIT_sd).div(timeDeltaAnnualized); 

        return price;
    }

    function exposureFactor(uint128 marketId) internal view returns (UD60x18 factor) {
        bytes32 marketType = Market.exists(marketId).marketType;
        if (marketType == Market.LINEAR_MARKET) {
            return UNIT_ud;
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
        int256 baseAmount,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (int256 annualizedExposure)
    {
        UD60x18 factor = annualizedExposureFactor(marketId, maturityTimestamp);
        annualizedExposure = mulUDxInt(factor, baseAmount);
    }

    function baseToExposure(
        int256 baseAmount,
        uint128 marketId
    )
        internal
        view
        returns (int256 exposure)
    {
        UD60x18 factor = exposureFactor(marketId);
        exposure = mulUDxInt(factor, baseAmount);
    }



    function getPnLComponents(
        PoolExposureState memory poolState,
        address poolAddress
    ) internal view returns (Account.PnLComponents memory pnlComponents) {

        UD60x18 twap = computeTwap(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool
        );

        pnlComponents.unrealizedPnL = computeUnrealizedPnL(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolState.baseBalance + poolState.baseBalancePool,
            poolState.quoteBalance + poolState.quoteBalancePool,
            twap
        );

        pnlComponents.realizedPnL = poolState.accruedInterest + poolState.accruedInterestPool;

        return pnlComponents;
    }

    function getExposureComponents(
        PoolExposureState memory poolState
    ) internal view returns (Account.ExposureComponents memory exposureComponents) {

        exposureComponents.filledExposure = mulUDxInt(
            poolState.annualizedExposureFactor,
            poolState.baseBalance + poolState.baseBalancePool
        );

        exposureComponents.cfExposureLong = mulUDxInt(
            poolState.annualizedExposureFactor,
            poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt()
        );

        exposureComponents.cfExposureShort = mulUDxInt(
            poolState.annualizedExposureFactor,
            poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt()
        );

        return exposureComponents;
    }

    function computePVMRUnwindPrice(
        UD60x18 avgPrice,
        UD60x18 diagonalRiskParameter,
        bool isLong
    ) private view returns (UD60x18 pvmrUnwindPrice) {
        // todo: note this doesn't take into account slippage & spread
        // todo: make sure add & sub is used correctly for long/short
        if (isLong) {
            avgPrice.add(diagonalRiskParameter);
        } else {
            avgPrice.sub(diagonalRiskParameter);
        }

        return pvmrUnwindPrice;
    }

    function getPVMRComponents(
        PoolExposureState memory poolState,
        address poolAddress,
        Account.RiskMatrixDimentions memory riskMatrixDim
    ) internal view returns (Account.PVMRComponents memory pvmrComponents) {

        UD60x18 diagonalRiskParameter;

        if ((poolState.unfilledBaseShort != 0) || (poolState.unfilledBaseLong != 0)) {
            address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();
            diagonalRiskParameter = IRiskConfigurationModule(coreProxy).getRiskMatrixParameterFromMM(
                poolState.marketId,
                riskMatrixDim.riskBlockId,
                riskMatrixDim.riskMatrixRowId,
                riskMatrixDim.riskMatrixRowId
            ).intoUD60x18();
        }

        if (poolState.unfilledBaseShort != 0) {

            int256 unrealizedPnLShort = computeUnrealizedPnL(
                poolState.marketId,
                poolState.maturityTimestamp,
                poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt(),
                poolState.quoteBalance + poolState.quoteBalancePool + poolState.unfilledQuoteShort.toInt(),
                computePVMRUnwindPrice(poolState.avgShortPrice, diagonalRiskParameter, false)
            );

            pvmrComponents.pvmrShort = unrealizedPnLShort > 0 ? 0 : (-unrealizedPnLShort).toUint();
        }

        if (poolState.unfilledBaseLong != 0) {

            int256 unrealizedPnLLong = computeUnrealizedPnL(
                poolState.marketId,
                poolState.maturityTimestamp,
                poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt(),
                poolState.quoteBalance + poolState.quoteBalancePool - poolState.unfilledQuoteLong.toInt(),
                computePVMRUnwindPrice(poolState.avgLongPrice, diagonalRiskParameter, true)
            );

            pvmrComponents.pvmrLong = unrealizedPnLLong > 0 ? 0 : (-unrealizedPnLLong).toUint();
        }

        return pvmrComponents;
    }

    function checkPositionSizeLimit(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal view {

        // todo: consider separate limit check for makers and takers

        Market.Data storage market = Market.exists(marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);

        Account.MarketExposure memory exposure =
            portfolio.getAccountExposuresPerMaturity(address(pool), maturityTimestamp);

        uint256 positionSize = SignedMath.abs(
            exposure.exposureComponents.cfExposureShort > exposure.exposureComponents.cfExposureLong ?
                exposure.exposureComponents.cfExposureShort  :
                exposure.exposureComponents.cfExposureLong
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
}
