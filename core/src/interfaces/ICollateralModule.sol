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
     * @notice Returns the total balance pertaining to account `accountId` for `collateralType`.
     * @param accountId The id of the account whose collateral is being queried.
     * @param collateralType The address of the collateral type whose amount is being queried.
     * @return collateralBalance The total collateral deposited in the account, denominated in
     * the token's native decimal representation.
     */
    function getAccountCollateralBalance(uint128 accountId, address collateralType)
        external
        view
        returns (uint256 collateralBalance);

    /**
     * @notice Returns the amount of collateral of type `collateralType` deposited with account `accountId` that can be withdrawn
     * @param accountId The id of the account whose collateral is being queried.
     * @param collateralType The address of the collateral type whose amount is being queried.
     * @return amount The amount of collateral that is available for withdrawal (difference between balance and IM), denominated
     * in the token's native decimal representation.
     */
    function getAccountWithdrawableCollateralBalance(uint128 accountId, address collateralType)
        external
        returns (uint256 amount);
}
