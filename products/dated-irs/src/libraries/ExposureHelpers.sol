/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Portfolio.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import "../storage/RateOracleReader.sol";
import "../interfaces/IPool.sol";
import "@voltz-protocol/core/src/interfaces/IRiskConfigurationModule.sol";
import "../storage/MarketManagerConfiguration.sol";

/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library ExposureHelpers {
    using SafeCastU256 for uint256;
    using RateOracleReader for RateOracleReader.Data;

    struct PoolExposureState {
        uint128 marketId;
        uint32 maturityTimestamp;
        UD60x18 annualizedExposureFactor;

        int256 baseBalance;
        int256 quoteBalance;

        int256 baseBalancePool;
        int256 quoteBalancePool;

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

        UD60x18 currentLiquidityIndex = RateOracleReader.load(marketId).getRateIndexCurrent();

        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        uint32 lookbackWindow =
            IRiskConfigurationModule(coreProxy).getMarketRiskConfiguration(marketId).twapLookbackWindow;

        UD60x18 twap = IPool(poolAddress).getAdjustedDatedIRSTwap(marketId, maturityTimestamp, -baseAmount, lookbackWindow);

        unwindQuote = mulUDxInt(twap.mul(timeDeltaAnnualized).add(UNIT), mulUDxInt(currentLiquidityIndex, baseAmount));
    }

    /**
     * @dev in context of interest rate swaps, base refers to scaled variable tokens (e.g. scaled virtual aUSDC)
     * @dev in order to derive the annualized exposure of base tokens in quote terms (i.e. USDC), we need to
     * first calculate the (non-annualized) exposure by multiplying the baseAmount by the current liquidity index of the
     * underlying rate oracle (e.g. aUSDC lend rate oracle)
     */
    function annualizedExposureFactor(uint128 marketId, uint32 maturityTimestamp) internal view returns (UD60x18 factor) {
        UD60x18 currentLiquidityIndex = RateOracleReader.load(marketId).getRateIndexCurrent();
        UD60x18 timeDeltaAnnualized = Time.timeDeltaAnnualized(maturityTimestamp);
        factor = currentLiquidityIndex.mul(timeDeltaAnnualized);
    }

    function baseToAnnualizedExposure(
        int256[] memory baseAmounts,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        internal
        view
        returns (int256[] memory exposures)
    {
        exposures = new int256[](baseAmounts.length);
        UD60x18 factor = annualizedExposureFactor(marketId, maturityTimestamp);

        for (uint256 i = 0; i < baseAmounts.length; i++) {
            exposures[i] = mulUDxInt(factor, baseAmounts[i]);
        }
    }

    function getUnfilledExposureLowerInPool(
        PoolExposureState memory poolState,
        address poolAddress
    ) internal view returns (AccountExposure.MarketExposure memory) {
        uint256 unrealizedLossLower = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool + poolState.unfilledQuoteShort.toInt()
        );

        return AccountExposure.MarketExposure({
            annualizedNotional: mulUDxInt(
                poolState.annualizedExposureFactor, 
                poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt()
            ),
            unrealizedLoss: unrealizedLossLower
        });
    }

    function getUnfilledExposureUpperInPool(
        PoolExposureState memory poolState,
        address poolAddress
    ) internal view returns (AccountExposure.MarketExposure memory) {
        uint256 unrealizedLossUpper = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool - poolState.unfilledQuoteLong.toInt()
        );

        return AccountExposure.MarketExposure({
            annualizedNotional: mulUDxInt(
                poolState.annualizedExposureFactor,
                poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt()
            ),
            unrealizedLoss: unrealizedLossUpper
        });
    }
}
