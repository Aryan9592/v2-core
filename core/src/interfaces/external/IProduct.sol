// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../../utils/contracts/interfaces/IERC165.sol";
import "../../storage/Account.sol";

/// @title Interface a Product needs to adhere.
interface IProduct is IERC165 {
    /// @notice returns a human-readable name for a given product
    function name() external view returns (string memory);

    /// @notice returns the unrealized pnl in quote token terms for account
    function getAccountUnrealizedPnL(uint128 accountId) external view returns (int256 unrealizedPnL);

    /**
     * @dev in context of interest rate swaps, base refers to scaled variable tokens (e.g. scaled virtual aUSDC)
     * @dev in order to derive the annualized exposure of base tokens in quote terms (i.e. USDC), we need to
     * first calculate the (non-annualized) exposure by multiplying the baseAmount by the current liquidity index of the
     * underlying rate oracle (e.g. aUSDC lend rate oracle)
     */
    function baseToAnnualizedExposure(int256[] memory baseAmounts, uint128 marketId, uint256 maturityTimestamp) 
        external view returns (int256[] memory exposures);

    /// @notice returns annualized filled notional, annualized unfilled notional long, annualized unfilled notional short
    function getAccountAnnualizedExposures(uint128 accountId) external returns (Account.Exposure[] memory exposures);

    // state-changing functions

    /// @notice attempts to close all the unfilled and filled positions of a given account in the product
    // if there are multiple maturities in which the account has active positions, the product is expected to close
    // all of them
    function closeAccount(uint128 accountId) external;
}
