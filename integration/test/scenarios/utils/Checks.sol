pragma solidity >=0.8.19;

import { AssertionHelpers } from "./AssertionHelpers.sol";
import { VammProxy } from "../../../src/proxies/Vamm.sol";
import { DatedIrsProxy } from "../../../src/proxies/DatedIrs.sol";

import { unwrap } from "@prb/math/UD60x18.sol";

import {
    FilledBalances,
    UnfilledBalances,
    OrderDirection
} from "@voltz-protocol/products-dated-irs/src/libraries/DataTypes.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

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
        UnfilledBalances memory unfilledBalances = getVammProxy().getAccountUnfilledBalances(
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
        OrderDirection orderDirection,
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

    function getVammProxy() internal view virtual returns (VammProxy);

    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view virtual returns (uint32);
}
