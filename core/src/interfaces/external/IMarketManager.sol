/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "../../storage/Account.sol";

/// @title Interface a Market Manager needs to adhere.
interface IMarketManager is IERC165 {
    //// VIEW FUNCTIONS ////

    /// @notice returns a human-readable name for a given market
    function name() external view returns (string memory);

    /// @notice returns account taker and maker exposures for a given account and collateral type
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId)
        external
        view
        returns (Account.MakerMarketExposure[] memory exposures);

    //// STATE CHANGING FUNCTIONS ////

    /// @notice attempts to close all the unfilled and filled positions of a given account in the market
    // if there are multiple maturities in which the account has active positions, the market is expected to close
    // all of them
    function closeAccount(uint128 marketId, uint128 accountId) external;
}
