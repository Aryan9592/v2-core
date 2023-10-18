/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Auto Exchange Module Interface
 */
interface IAutoExchangeModule {

    // todo: consider returning more information (like we do with liquidations)
    /**
     * @notice Checks if an account is eligble for auto-exchange
     * @param accountId The id of the account that is being checked for auto-exchange eligibility
     * @param token The quote token's address to be covered in the auto exchange
     * @return isEligibleForAutoExchange True if the account collateral is liquidatable for a given quote
     * token
     */
    function isEligibleForAutoExchange(uint128 accountId, address token) external view returns (
        bool isEligibleForAutoExchange
    );

    // todo: add natspec & return more information
    function triggerAutoExchange(
        uint128 accountId,
        uint128 liquidatorAccountId,
        uint256 amountToAutoExchangeQuote,
        address collateralType,
        address quoteType
    ) external;

}