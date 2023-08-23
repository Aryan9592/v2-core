/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";

/**
 * @title System-wide entry point for the management of markets connected to the protocol.
 */
interface IMarketManagerModule {
    /**
     * @notice Thrown when an attempt to register a market that does not conform to the IMarketManager interface is made.
     */
    error IncorrectMarketInterface(address market);

    /**
     * @notice Emitted when a new market is registered in the protocol.
     * @param marketManager The address of the market that was registered in the system.
     * @param marketId The id with which the market was registered in the system.
     * @param sender The account that trigger the registration of the market and also the owner of the market.
     * @param blockTimestamp The current block timestamp.
     */
    event MarketRegistered(
        address indexed marketManager, 
        uint128 indexed marketId, 
        string name, 
        address indexed sender, 
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when account token with id `accountId` is closed.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param sender The initiator of the account closure.
     * @param blockTimestamp The current block timestamp.
     */
    event AccountClosed(uint128 indexed accountId, uint128 indexed marketId, address sender, uint256 blockTimestamp);

    /// @notice returns the id of the last created market
    function getLastCreatedMarketId() external returns (uint128);


    /// @notice returns account taker and maker exposures for a given market, account and collateral type
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId)
        external
        returns (Account.MakerMarketExposure[] memory exposures);

    //// STATE CHANGING FUNCTIONS ////

    /**
     * @notice Connects a market to the system.
     * @dev Creates a market object to track the market, and returns the newly created market id.
     * @param market The address of the market that is to be registered in the system.
     * @dev On the other hand, trustless markets can be registered by anyone
     * @return newMarketId The id with which the market will be registered in the system.
     */
    function registerMarket(address market, string memory name) external returns (uint128 newMarketId);

    /// @notice attempts to close all the unfilled and filled positions of a given account in a given market (marketId)
    function closeAccount(uint128 marketId, uint128 accountId) external;

    function propagateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external returns (uint256 fee);

    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external returns (uint256 fee);


    function propagateCashflow(uint128 accountId, uint128 marketId, address collateralType, int256 amount) external;
}
