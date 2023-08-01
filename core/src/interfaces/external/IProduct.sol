/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "../../storage/Account.sol";

/// @title Interface a Product needs to adhere.
interface IProduct is IERC165 {
    //// VIEW FUNCTIONS ////
    /// @notice returns account taker and maker exposures for a given account and collateral type
    function getAccountTakerAndMakerExposures(uint128 accountId, address collateralType)
        external
        view
        returns (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        );

    /// @notice returns account taker and maker exposures for a given account across all collateral types
    function getAccountTakerAndMakerExposuresAllCollaterals(uint128 accountId)
    external
    view
    returns (
        Account.Exposure[] memory takerExposures,
        Account.Exposure[] memory makerExposuresLower,
        Account.Exposure[] memory makerExposuresUpper
    );

    //// STATE CHANGING FUNCTIONS ////

    /// @notice attempts to close all the unfilled and filled positions of a given account in the product
    // if there are multiple maturities in which the account has active positions, the product is expected to close
    // all of them
    function closeAccount(uint128 accountId, address collateralType) external;
}
