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

    /**
     * @dev Thrown when an account is not eligible for auto-exchange
     */
    error AccountNotEligibleForAutoExchange(uint128 accountId);

    /**
     * @dev Thrown when attempting to auto-exchange single-token accounts which do not cross
     * collateral margin -> not susceptible to exchange rate risk
     */
    error AccountIsSingleTokenNoExposureToExchangeRateRisk(uint128 accountId);


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


    // todo: consider returning relevant information post auto-exchange
    function triggerAutoExchange(uint128 autoExchangeAccountId, uint128 autoExchangeTriggerAccountId,
        uint256 amountToAutoExchange, address collateralType, address quoteType) external;

    /** 
    * @notice Returns the maximum amount that can be exchanged, represented in quote token
    * @dev maxAmountQuote = min(
        abs(min(0, collateralBalanceInQuote + rPnLInQuote + uPnLInQuote)) * autoExchangeRatio,
        collateralBalanceInCollateralTokenRepresentedInQuote 
        )
    */
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address collateralType,
        address quoteType
    ) external returns (uint256 maxAmountQuote);

}