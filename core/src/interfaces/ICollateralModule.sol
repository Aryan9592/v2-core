/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Module for managing user collateral.
 * @notice Allows users to deposit and withdraw collateral from the protocol
 */
interface ICollateralModule {

    /**
     * @notice Returns the net deposits pertaining to account `accountId` for `collateralType`.
     * @param accountId The id of the account whose collateral is being queried.
     * @param collateralType The address of the collateral type whose amount is being queried.
     * @return netDeposits The net deposits in the account, denominated in
     * the token's native decimal representation.
     */
    function getAccountNetCollateralDeposits(uint128 accountId, address collateralType)
        external
        view
        returns (int256 netDeposits);

    /**
     * @notice Returns the amount of collateral of type `collateralType` that can be withdrawn from the account
     * @param accountId The id of the account whose collateral is being queried.
     * @param collateralType The address of the collateral type whose amount is being queried.
     * @return amount The amount of collateral that is available for withdrawal, denominated
     * in the token's native decimal representation.
     */
    function getAccountWithdrawableCollateralBalance(uint128 accountId, address collateralType)
        external
        returns (uint256 amount);
}
