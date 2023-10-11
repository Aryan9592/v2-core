pragma solidity >=0.8.19;

import {AssertionHelpers} from "./AssertionHelpers.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IPool} from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";
import {VammProxy} from "../../../src/proxies/Vamm.sol";
import {DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";
import {VammTicks} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";

import { UD60x18, ud, unwrap, convert } from "@prb/math/UD60x18.sol";

import { FilledBalances, UnfilledBalances } from "@voltz-protocol/products-dated-irs/src/libraries/DataTypes.sol";

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
    ) internal {
        int256 sumFilledBase = 0;
        int256 sumFilledQuote = 0;
        int256 sumAccruedInterest = 0;

        for (uint256 i = 0; i < accountIds.length; i++) {
            FilledBalances memory filledBalances = datedIrsProxy
                .getAccountFilledBalances(marketId, maturityTimestamp, accountIds[i]);
            
            sumFilledBase += filledBalances.base;
            sumFilledQuote += filledBalances.quote;

            sumAccruedInterest += filledBalances.accruedInterest;
        }
        
        assertAlmostEq(sumFilledBase, int(0), EPSILON, "sumFilledBase");
        assertAlmostEq(sumFilledQuote, int(0), EPSILON, "sumFilledQuote");
        assertAlmostEq(sumAccruedInterest, int(0), EPSILON, "sumAccruedInterest");
    }
    
    function checkFilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        int256 expectedBaseBalance,
        int256 expectedQuoteBalance,
        int256 expectedAccruedInterest
    ) internal {
        FilledBalances memory filledBalances = datedIrsProxy
            .getAccountFilledBalances(positionInfo.marketId, positionInfo.maturityTimestamp, positionInfo.accountId);

        assertAlmostEq(expectedBaseBalance, filledBalances.base, EPSILON, "filledBase");
        assertAlmostEq(expectedQuoteBalance, filledBalances.quote, EPSILON, "filledQuote");
        assertAlmostEq(expectedAccruedInterest, filledBalances.accruedInterest, EPSILON, "accruedInterest");
    }

    function checkZeroFilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo
    ) internal {
        checkFilledBalances({
            datedIrsProxy: datedIrsProxy,
            positionInfo: positionInfo,
            expectedBaseBalance: 0, 
            expectedQuoteBalance: 0,
            expectedAccruedInterest: 0
        });
    }

    function checkUnfilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        uint256 expectedUnfilledBaseLong,
        uint256 expectedUnfilledBaseShort,
        uint256 expectedUnfilledQuoteLong,
        uint256 expectedUnfilledQuoteShort
    ) internal {
        UnfilledBalances memory unfilledBalances = datedIrsProxy.getAccountUnfilledBaseAndQuote(
            positionInfo.marketId, 
            positionInfo.maturityTimestamp, 
            positionInfo.accountId
        );


        assertAlmostEq(int(expectedUnfilledBaseLong), int(unfilledBalances.baseLong), EPSILON, "unfilledBaseLong");
        assertAlmostEq(int(expectedUnfilledBaseShort), int(unfilledBalances.baseShort), EPSILON, "unfilledBaseShort");
        assertAlmostEq(int(expectedUnfilledQuoteLong), int(unfilledBalances.quoteLong), EPSILON, "unfilledQuoteLong");
        assertAlmostEq(int(expectedUnfilledQuoteShort), int(unfilledBalances.quoteShort), EPSILON, "unfilledQuoteShort");
        // todo: add additional assertions for average prices
    }

    function checkZeroUnfilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo
    ) internal {
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
        uint128 marketId, uint32 maturityTimestamp, int256 orderSize
    ) internal view returns (uint256 twap) {
        twap = unwrap(
            getVammProxy().getAdjustedTwap(
                marketId, 
                maturityTimestamp, 
                orderSize, 
                twapLookbackWindow(marketId, maturityTimestamp)
            )
        );
    }

    function getVammProxy() internal virtual view returns(VammProxy);
    
    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view virtual returns(uint32);
}
