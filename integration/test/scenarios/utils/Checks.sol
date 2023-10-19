pragma solidity >=0.8.19;

import { AssertionHelpers } from "./AssertionHelpers.sol";
import { VammProxy } from "../../../src/proxies/Vamm.sol";
import { DatedIrsProxy } from "../../../src/proxies/DatedIrs.sol";

import { unwrap } from "@prb/math/UD60x18.sol";

import { FilledBalances, UnfilledBalances } from "@voltz-protocol/products-dated-irs/src/libraries/DataTypes.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

import { IPool } from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";
import { Account }  from "@voltz-protocol/core/src/storage/Account.sol";

/// @title Storage checks
abstract contract Checks is AssertionHelpers {
    struct PositionInfo {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
    }

    uint256 public constant EPSILON = 10;

    function checkTotalFilledBalances(
        DatedIrsProxy datedIrsProxy,
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128[] memory accountIds
    )
        internal
    {
        int256 sumFilledBase = 0;
        int256 sumFilledQuote = 0;
        int256 sumRealizedPnL = 0;

        for (uint256 i = 0; i < accountIds.length; i++) {
            FilledBalances memory filledBalances =
                datedIrsProxy.getAccountFilledBalances(marketId, maturityTimestamp, accountIds[i]);

            sumFilledBase += filledBalances.base;
            sumFilledQuote += filledBalances.quote;

            sumRealizedPnL += filledBalances.pnl.realizedPnL;
        }

        assertAlmostEq(sumFilledBase, int256(0), EPSILON, "sumFilledBase");
        assertAlmostEq(sumFilledQuote, int256(0), EPSILON, "sumFilledQuote");
        assertAlmostEq(sumRealizedPnL, int256(0), EPSILON, "sumRealizedPnL");
    }

    function checkFilledBalancesWithoutUPnL(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        int256 expectedBaseBalance,
        int256 expectedQuoteBalance,
        int256 expectedRealizedPnL
    )
        internal
    {
        FilledBalances memory filledBalances = datedIrsProxy.getAccountFilledBalances(
            positionInfo.marketId, positionInfo.maturityTimestamp, positionInfo.accountId
        );

        assertAlmostEq(expectedBaseBalance, filledBalances.base, EPSILON, "filledBase");
        assertAlmostEq(expectedQuoteBalance, filledBalances.quote, EPSILON, "filledQuote");
        assertAlmostEq(expectedRealizedPnL, filledBalances.pnl.realizedPnL, EPSILON, "realizedPnL");
    }

    function checkFilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        int256 expectedBaseBalance,
        int256 expectedQuoteBalance,
        int256 expectedRealizedPnL,
        int256 expectedUnrealizedPnL
    )
        internal
    {
        FilledBalances memory filledBalances = datedIrsProxy.getAccountFilledBalances(
            positionInfo.marketId, positionInfo.maturityTimestamp, positionInfo.accountId
        );

        assertAlmostEq(expectedBaseBalance, filledBalances.base, EPSILON, "filledBase");
        assertAlmostEq(expectedQuoteBalance, filledBalances.quote, EPSILON, "filledQuote");
        assertAlmostEq(expectedRealizedPnL, filledBalances.pnl.realizedPnL, EPSILON, "realizedPnL");
        assertAlmostEq(expectedUnrealizedPnL, filledBalances.pnl.unrealizedPnL, EPSILON, "unrealizedPnL");
    }

    function checkZeroFilledBalances(DatedIrsProxy datedIrsProxy, PositionInfo memory positionInfo) internal {
        checkFilledBalances({
            datedIrsProxy: datedIrsProxy,
            positionInfo: positionInfo,
            expectedBaseBalance: 0,
            expectedQuoteBalance: 0,
            expectedRealizedPnL: 0,
            expectedUnrealizedPnL: 0
        });
    }

    function checkUnfilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        uint256 expectedUnfilledBaseLong,
        uint256 expectedUnfilledBaseShort,
        uint256 expectedUnfilledQuoteLong,
        uint256 expectedUnfilledQuoteShort
    )
        internal
    {
        UnfilledBalances memory unfilledBalances = datedIrsProxy.getAccountUnfilledBaseAndQuote(
            positionInfo.marketId, positionInfo.maturityTimestamp, positionInfo.accountId
        );

        assertAlmostEq(int256(expectedUnfilledBaseLong), int256(unfilledBalances.baseLong), EPSILON, "unfilledBaseLong");
        assertAlmostEq(
            int256(expectedUnfilledBaseShort), int256(unfilledBalances.baseShort), EPSILON, "unfilledBaseShort"
        );
        assertAlmostEq(
            int256(expectedUnfilledQuoteLong), int256(unfilledBalances.quoteLong), EPSILON, "unfilledQuoteLong"
        );
        assertAlmostEq(
            int256(expectedUnfilledQuoteShort), int256(unfilledBalances.quoteShort), EPSILON, "unfilledQuoteShort"
        );
        // todo: add additional assertions for average prices
    }

    function checkZeroUnfilledBalances(DatedIrsProxy datedIrsProxy, PositionInfo memory positionInfo) internal {
        checkUnfilledBalances({
            datedIrsProxy: datedIrsProxy,
            positionInfo: positionInfo,
            expectedUnfilledBaseLong: 0,
            expectedUnfilledBaseShort: 0,
            expectedUnfilledQuoteLong: 0,
            expectedUnfilledQuoteShort: 0
        });
    }

    function getAdjustedTwap(
        uint128 marketId,
        uint32 maturityTimestamp,
        IPool.OrderDirection orderDirection,
        UD60x18 pSlippage
    )
        internal
        view
        returns (uint256 twap)
    {
        twap = unwrap(
            getVammProxy().getAdjustedTwap(
                marketId, maturityTimestamp, orderDirection, twapLookbackWindow(marketId, maturityTimestamp), pSlippage
            )
        );
    }

    function checkValidLiquidationOrder(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        int256 baseAmountToBeLiquidated,
        uint160 priceLimit,
        bool expectedIsValid
    ) internal {
        bytes memory inputs = abi.encode(positionInfo.maturityTimestamp, baseAmountToBeLiquidated, priceLimit);

        try datedIrsProxy.validateLiquidationOrder(positionInfo.accountId, 0, positionInfo.marketId, inputs) {
            assertTrue(expectedIsValid, "checkValidLiquidationOrder-passes");
        } catch {
            assertFalse(expectedIsValid, "checkValidLiquidationOrder-fails");
        }
    }

    function checkTakerExposures_SingleMaturity(
        DatedIrsProxy datedIrsProxy,
        uint128 marketId,
        uint128 accountId,
        int256 expectedSwapFilledExposure,
        int256 expectedShortFilledExposure
    ) internal {
        int256[] memory filledExposures = 
            datedIrsProxy.getAccountTakerExposures(marketId, accountId, 2);

        assertEq(
            expectedSwapFilledExposure,
            filledExposures[1],
            "filledExposureSwap"
        );

        assertEq(
            expectedShortFilledExposure,
            filledExposures[0],
            "filledExposureShort"
        );
        
    }  

    function checkMakerExposures_SingleMaturity(
        DatedIrsProxy datedIrsProxy,
        uint128 marketId,
        uint128 accountId,
        int256 expectedUnfilledExposureLong_short,
        int256 expectedUnfilledExposureShort_short,
        int256 expectedUnfilledExposureLong_swap,
        int256 expectedUnfilledExposureShort_swap,
        uint256 expectedPvmrLong,
        uint256 expectedPvmrShort
    ) internal {
        Account.UnfilledExposure[] memory unfilledExposures = 
            datedIrsProxy.getAccountMakerExposures(marketId, accountId);

        assertEq(
            expectedUnfilledExposureLong_short,
            unfilledExposures[0].exposureComponents.long[0],
            "unfilledExposureLong_Short"
        );

        assertEq(
            expectedUnfilledExposureShort_short,
            unfilledExposures[0].exposureComponents.short[0],
            "unfilledExposureShort_Short"
        );

        assertEq(
            expectedUnfilledExposureLong_swap,
            unfilledExposures[0].exposureComponents.long[1],
            "unfilledExposureLong_Swap"
        );

        assertEq(
            expectedUnfilledExposureShort_swap,
            unfilledExposures[0].exposureComponents.short[1],
            "unfilledExposureShort_Swap"
        );

        assertEq(
            expectedPvmrLong,
            unfilledExposures[0].pvmrComponents.long,
            "pvmrLong"
        );

        assertEq(
            expectedPvmrShort,
            unfilledExposures[0].pvmrComponents.short,
            "pvmrShort"
        );

        assertEq(
            0,
            unfilledExposures[0].riskMatrixRowIds[0],
            "riskMatrixRowIds[0]"
        );

        assertEq(
            1,
            unfilledExposures[0].riskMatrixRowIds[1],
            "riskMatrixRowIds[1]"
        );
        
    }  

    function getVammProxy() internal view virtual returns (VammProxy);

    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view virtual returns (uint32);
}
