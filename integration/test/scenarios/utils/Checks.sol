pragma solidity >=0.8.19;

import {AssertionHelpers} from "./AssertionHelpers.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IPool} from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";
import {Position} from "@voltz-protocol/products-dated-irs/src/storage/Position.sol";
import {VammProxy} from "../../../src/proxies/Vamm.sol";
import {DatedIrsProxy} from "../../../src/proxies/DatedIrs.sol";
import {VammTicks} from "@voltz-protocol/v2-vamm/src/libraries/vamm-utils/VammTicks.sol";

import { UD60x18, ud, unwrap, convert } from "@prb/math/UD60x18.sol";

import "forge-std/console2.sol";

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
        
        assertAlmostEq(sumFilledBase, int(0), 1, "sumFilledBase");
        assertAlmostEq(sumFilledQuote, int(0), 1, "sumFilledQuote");
        // todo: complete
        // assertAlmostEq(sumAccruedInterest, int(0), 1, "sumAccruedInterest");
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
        // todo: complete
        // assertEq(expectedAccruedInterestPool, position.accruedInterestTrackers.accruedInterest, "accruedInterest");
    }

    function checkZeroTakerFilledBalances(
        DatedIrsProxy datedIrsProxy,
        PositionInfo memory positionInfo
    ) internal {
        checkTakerFilledBalances(datedIrsProxy, positionInfo, 0, 0, 0);
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
            uint256 unfilledQuoteShort
        ) = IPool(poolAddress).getAccountUnfilledBaseAndQuote(
            positionInfo.marketId, 
            positionInfo.maturityTimestamp, 
            positionInfo.accountId
        );

        assertEq(expectedUnfilledBaseLong, unfilledBaseLong, "unfilledBaseLong");
        assertEq(expectedUnfilledBaseShort, unfilledBaseShort, "unfilledBaseShort");
        assertEq(expectedUnfilledQuoteLong, unfilledQuoteLong, "unfilledQuoteLong");
        assertEq(expectedUnfilledQuoteShort, unfilledQuoteShort, "unfilledQuoteShort");
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

    function checkNonAdjustedTwap(uint128 marketId, uint32 maturityTimestamp) internal returns (uint256 twap) {
        VammProxy vammProxy = getVammProxy();
        int24 currentTick = vammProxy.getVammTick(marketId, maturityTimestamp);
        UD60x18 price = VammTicks.getPriceFromTick(currentTick).div(convert(100));

        UD60x18 datedIRSTwap = vammProxy.getAdjustedDatedIRSTwap(marketId, maturityTimestamp, 0, 0);
        console2.log("TICK", currentTick);
        
        twap = unwrap(price);
    }

    function getAdjustedTwap(
        uint128 marketId, uint32 maturityTimestamp, int256 orderSize
    ) internal returns (uint256 twap) {
        uint32 twapLookbackWindow = twapLookbackWindow(marketId,maturityTimestamp);
        VammProxy vammProxy = getVammProxy();

        twap = unwrap(
            vammProxy.getAdjustedDatedIRSTwap(marketId, maturityTimestamp, orderSize, twapLookbackWindow)
        );
    }

    function getVammProxy() internal virtual view returns(VammProxy);
    function twapLookbackWindow(uint128 marketId, uint32 maturityTimestamp) internal view virtual returns(uint32);
}

library StructsTransformer {

    struct MarginInfo {
        address collateralType;
        int256 netDeposits;
        /// These are all amounts that are available to contribute to cover margin requirements. 
        int256 marginBalance;
        /// The real balance is the balance that is in ‘cash’, that is, actually held in the settlement 
        /// token and not as value of an instrument which settles in that token
        int256 realBalance;
        /// Difference between margin balance and initial margin requirement
        int256 initialDelta;
        /// Difference between margin balance and maintenance margin requirement
        int256 maintenanceDelta;
        /// Difference between margin balance and liquidation margin requirement
        int256 liquidationDelta;
        /// Difference between margin balance and dutch margin requirement
        int256 dutchDelta;
        /// Difference between margin balance and adl margin requirement
        int256 adlDelta;
    }

    function marginInfo(Account.MarginInfo memory margin) internal pure returns (MarginInfo memory) {
        return MarginInfo({
            collateralType: margin.collateralType,
            netDeposits: margin.netDeposits,
            marginBalance: margin.marginBalance,
            realBalance: margin.realBalance,
            initialDelta: margin.initialDelta,
            maintenanceDelta: margin.maintenanceDelta,
            liquidationDelta: margin.liquidationDelta,
            dutchDelta: margin.dutchDelta, 
            adlDelta: margin.adlDelta
        });
    }
}