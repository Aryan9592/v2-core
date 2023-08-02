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
import "../storage/ProductConfiguration.sol";

/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library ExposureHelpers {
    using SafeCastU256 for uint256;
    using RateOracleReader for RateOracleReader.Data;

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
            // todo: check if safecasting with .Uint() is necessary (CR)
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

        address coreProxy = ProductConfiguration.getCoreProxyAddress();
        uint128 productId = ProductConfiguration.getProductId();
        uint32 lookbackWindow =
            IRiskConfigurationModule(coreProxy).getMarketRiskConfiguration(productId, marketId).twapLookbackWindow;

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

    function removeEmptySlotsFromExposuresArray(
        Account.Exposure[] memory exposures,
        uint256 length
    ) internal pure returns (Account.Exposure[] memory exposuresWithoutEmptySlots) {
        // todo: consider into a utility library (CR)
        require(exposures.length >= length, "Exp len");
        exposuresWithoutEmptySlots = new Account.Exposure[](length);
        for (uint256 i = 0; i < length; i++) {
            exposuresWithoutEmptySlots[i] = exposures[i];
        }
    }

    function getOnlyFilledExposureInPool(
        Portfolio.PoolExposureState memory poolState,
        address poolAddress,
        address collateralType,
        uint128 productId
    ) internal view returns (Account.Exposure memory) {
        uint256 unrealizedLoss = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool,
            poolState.quoteBalance + poolState.quoteBalancePool
        );
        return Account.Exposure({
            productId: productId,
            marketId: poolState.marketId,
            annualizedNotional: mulUDxInt(poolState._annualizedExposureFactor, poolState.baseBalance + poolState.baseBalancePool),
            unrealizedLoss: unrealizedLoss,
            collateralType: collateralType
        });
    }

    function getUnfilledExposureLowerInPool(
        Portfolio.PoolExposureState memory poolState,
        address poolAddress,
        address collateralType,
        uint128 productId
    ) internal view returns (Account.Exposure memory) {
        uint256 unrealizedLossLower = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool + poolState.unfilledQuoteShort.toInt()
        );
        return Account.Exposure({
            productId: productId,
            marketId: poolState.marketId,
            annualizedNotional: mulUDxInt(
                poolState._annualizedExposureFactor, 
                poolState.baseBalance + poolState.baseBalancePool - poolState.unfilledBaseShort.toInt()
            ),
            unrealizedLoss: unrealizedLossLower,
            collateralType: collateralType
        });
    }

    function getUnfilledExposureUpperInPool(
        Portfolio.PoolExposureState memory poolState,
        address poolAddress,
        address collateralType,
        uint128 productId
    ) internal view returns (Account.Exposure memory) {
        uint256 unrealizedLossUpper = computeUnrealizedLoss(
            poolState.marketId,
            poolState.maturityTimestamp,
            poolAddress,
            poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt(),
            poolState.quoteBalance + poolState.quoteBalancePool - poolState.unfilledQuoteLong.toInt()
        );
        return Account.Exposure({
            productId: productId,
            marketId: poolState.marketId,
            annualizedNotional: mulUDxInt(
                poolState._annualizedExposureFactor,
                poolState.baseBalance + poolState.baseBalancePool + poolState.unfilledBaseLong.toInt()
            ),
            unrealizedLoss: unrealizedLossUpper,
            collateralType: collateralType
        });
    }
}
