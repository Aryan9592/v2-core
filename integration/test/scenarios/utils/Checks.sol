/**
  conditions check: 
    - protocol is correctly setup (i.e. vamm, pool, market manager storage)
    - checking balances of a trader:
        - pool balance (storage)
        - instrument balance (storage)
        - exposure
        - can add any other storage checks to this contract
        --- pass expected values and position info to these functions
    - actions
    - post conditions
        - protocol solvency
            - check account margin requirement 
*/

pragma solidity >=0.8.19;

import {AssertionHelpers} from "./AssertionHelpers.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IPool} from "@voltz-protocol/products-dated-irs/src/interfaces/IPool.sol";

/// @title Storage checks 
contract Checks is AssertionHelpers {

    struct PositionInfo {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
    }
    
    function checkFilledBalances(
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