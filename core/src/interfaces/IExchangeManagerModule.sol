/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


/**
 * @title System-wide entry point for the management of markets connected to the protocol.
 */
interface IExchangeManagerModule {

    error OnlyExchangePassOwner();

    /**
     * @notice Emitted when a new exchange is registered in the protocol.
     * @param exchangeId The id with which the market was registered in the system.
     * @param blockTimestamp The current block timestamp.
     */
    event ExchangeRegistered(
        uint128 indexed exchangeId,
        uint256 blockTimestamp
    );

    /// @notice returns the id of the last created exchange
    function getLastCreatedExchangeId() external returns (uint128);

    //// STATE CHANGING FUNCTIONS ////

    /**
     * @notice Connects an exchange to the system.
     * @return exchangeId The id with which the market will be registered in the system.
     */
    function registerExchange(uint128 exchangeFeeCollectorAccountId) external returns (uint128 exchangeId);


}