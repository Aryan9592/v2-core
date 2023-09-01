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
     * @notice Checks if a multi-token account is eligble for auto-exchange
     * @param accountId The id of the account that is being checked for auto-exchange eligibility
     * @param quoteType The settlement token's address to be covered in the auto exchange
     * @return isEligibleForAutoExchange True if the account is liquidatable
     */
    function isEligibleForAutoExchange(uint128 accountId, address quoteType) external view returns (
        bool isEligibleForAutoExchange
    );

    /** 
     * @notice Returns the maximum amount that can be exchanged, represented in quote token
     * @param accountId The id of the account
     * @param coveringToken The collateral that is supposed to be used for covering the insufficient collateral
     * @param autoExchangedToken The insufficient collateral that will be auto-exchanged
     * @return coveringAmount The amount of `coveringToken` used to cover the insufficient collateral
     * @return autoExchangedAmount The maximum amount of `autoExchangedToken` equivalent to `coveringAmount`
    */
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address coveringToken,
        address autoExchangedToken
    ) external view returns (uint256 coveringAmount, uint256 autoExchangedAmount);
}