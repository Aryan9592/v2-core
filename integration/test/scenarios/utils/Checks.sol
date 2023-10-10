pragma solidity >=0.8.19;

import {AssertionHelpers} from "./AssertionHelpers.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IPool} from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";
import {Position} from "@voltz-protocol/products-dated-irs/src/storage/Position.sol";
import {VammProxy} from "../../../src/proxies/Vamm.sol";
import {DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";
import {VammTicks} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";

import { UD60x18, ud, unwrap, convert } from "@prb/math/UD60x18.sol";

/// @title Storage checks 
abstract contract Checks is AssertionHelpers {

    struct PositionInfo {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
    }

    function checkTotalFilledBalances(
        address poolAddress,
        DatedIrsProxy datedIrsProxy,
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128[] memory accountIds
    ) internal {
        int256 sumFilledBase = 0;
        int256 sumFilledQuote = 0;
        int256 sumAccruedInterest = 0;

        for (uint256 i = 0; i < accountIds.length; i++) {
            (
                int256 baseBalancePool,
                int256 quoteBalancePool,
                int256 accruedInterestPool
            ) = IPool(poolAddress)
                .getAccountFilledBalances(marketId, maturityTimestamp, accountIds[i]);
            Position.Data memory position = datedIrsProxy
                .getTakerPositionInfo(accountIds[i], marketId, maturityTimestamp);

            sumFilledBase += (baseBalancePool + position.baseBalance);
            sumFilledQuote += (quoteBalancePool + position.quoteBalance);

            sumAccruedInterest += (accruedInterestPool + position.accruedInterestTrackers.accruedInterest);
        }
        
        assertAlmostEq(sumFilledBase, int(0), 1e4, "sumFilledBase");
        assertAlmostEq(sumFilledQuote, int(0), 1e4, "sumFilledQuote");
        assertAlmostEq(sumAccruedInterest, int(0), 1e4, "sumAccruedInterest");
    }
    
    function checkPoolFilledBalances(
        address poolAddress,
        PositionInfo memory positionInfo,
        int256 expectedBaseBalancePool,
        int256 expectedQuoteBalancePool,
        int256 expectedAccruedInterestPool
    ) internal {
        (
            int256 baseBalancePool,
            int256 quoteBalancePool,
            int256 accruedInterestPool
        ) = IPool(poolAddress)
            .getAccountFilledBalances(positionInfo.marketId, positionInfo.maturityTimestamp, positionInfo.accountId);

        assertEq(expectedBaseBalancePool, baseBalancePool, "baseBalancePool");
        assertEq(expectedQuoteBalancePool, quoteBalancePool, "quoteBalancePool");
        assertEq(expectedAccruedInterestPool, accruedInterestPool, "accruedInterestPool");
    }

    function checkTakerFilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo,
        int256 expectedBaseBalancePool,
        int256 expectedQuoteBalancePool,
        int256 expectedAccruedInterestPool
    ) internal {
        Position.Data memory position = datedIrsProxy
            .getTakerPositionInfo(positionInfo.accountId, positionInfo.marketId, positionInfo.maturityTimestamp);

        assertEq(expectedBaseBalancePool, position.baseBalance, "baseBalance");
        assertEq(expectedQuoteBalancePool, position.quoteBalance, "quoteBalance");
        assertEq(expectedAccruedInterestPool, position.accruedInterestTrackers.accruedInterest, "accruedInterest");
    }

    function checkZeroPoolFilledBalances(
        address poolAddress,
        PositionInfo memory positionInfo
    ) internal {
        checkPoolFilledBalances({
            poolAddress: poolAddress,
            positionInfo: positionInfo,
            expectedBaseBalancePool: 0, 
            expectedQuoteBalancePool: 0,
            expectedAccruedInterestPool: 0
        });
    }

    function checkUnfilledBalances(
        address poolAddress,
        PositionInfo memory positionInfo,
        uint256 expectedUnfilledBaseLong,
        uint256 expectedUnfilledBaseShort,
        uint256 expectedUnfilledQuoteLong,
        uint256 expectedUnfilledQuoteShort
    ) internal {

        (
            uint256 unfilledBaseLong,
            uint256 unfilledBaseShort,
            uint256 unfilledQuoteLong,
            uint256 unfilledQuoteShort,,
        ) = IPool(poolAddress).getAccountUnfilledBaseAndQuote(
            positionInfo.marketId, 
            positionInfo.maturityTimestamp, 
            positionInfo.accountId
        );

        assertEq(expectedUnfilledBaseLong, unfilledBaseLong, "unfilledBaseLong");
        assertEq(expectedUnfilledBaseShort, unfilledBaseShort, "unfilledBaseShort");
        assertEq(expectedUnfilledQuoteLong, unfilledQuoteLong, "unfilledQuoteLong");
        assertEq(expectedUnfilledQuoteShort, unfilledQuoteShort, "unfilledQuoteShort");

        // todo: add additional assertions for average prices
    }

    function checkZeroUnfilledBalances(
        address poolAddress,
        PositionInfo memory positionInfo
    ) internal {
        checkUnfilledBalances({
            poolAddress: poolAddress,
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
            getVammProxy().getAdjustedDatedIRSTwap(
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
