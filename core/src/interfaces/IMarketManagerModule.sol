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
        address quoteToken,
        string name, 
        address indexed sender, 
        uint256 blockTimestamp
    );

    /// @notice returns the id of the last created market
    function getLastCreatedMarketId() external returns (uint128);


    /// @notice returns account taker and maker exposures for a given market and account
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId, uint256 riskMatrixDim)
        external
        returns (
        int256[] memory filledExposures,
        Account.UnfilledExposure[] memory unfilledExposures
    );

    //// STATE CHANGING FUNCTIONS ////

    /**
     * @notice Connects a market to the system.
     * @dev Creates a market object to track the market, and returns the newly created market id.
     * @param market The address of the instrument that powers the market to be registered in the system.
     * @dev Markets can be registered by anyone
     * @param name Name of the market
     * @return newMarketId The id with which the market will be registered in the system.
     */
    function registerMarket(address market, address quoteToken, string memory name) external returns (uint128 newMarketId);
}
