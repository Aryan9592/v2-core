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
    function name() external pure returns (string memory);

    /// @notice returns a magic number proving the contract was built for the protocol
    function isMarketManager() external pure returns (bool);

    /// @notice Returns the market's quote token address
    function getMarketQuoteToken(uint128 marketId) external view returns (address);

    /// @notice returns account taker and maker exposures for a given account and collateral type
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId)
        external
        view
        returns (Account.MakerMarketExposure[] memory exposures);

    //// STATE CHANGING FUNCTIONS ////

    /// @notice attempts to close all the unfilled orders of a given account in the market
    // if there are multiple maturities in which the account has active positions, the market is expected to close
    // all of them
    function closeAllUnfilledOrders(uint128 marketId, uint128 accountId) external;
    
    /**
     * @notice Decoded inputs and execute taker order
     * @param accountId Id of the account that wants to initiate a taker order
     * @param marketId Id of the market in which the account wants to initiate a taker order
     * @param inputs The extra inputs required by the taker order
     *
     * Requirements:
     *
     * - `msg.sender` must be Core.
     *
     */
    function executeTakerOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external returns (bytes memory output, int256 annualizedNotional);

    /**
     * @notice Decoded inputs and execute maker order
     * @param accountId Id of the account that wants to initiate a maker order
     * @param marketId Id of the market in which the account wants to initiate a maker order
     * @param inputs The extra inputs required by the maker order
     *
     * Requirements:
     *
     * - `msg.sender` must be Core.
     *
     */
    function executeMakerOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external returns (bytes memory output, int256 annualizedNotional);

    /**
     * @notice Decoded inputs and execute liquidation order
     * @param liquidatableAccountId Id of the account that is getting liquidated
     * @param liquidatorAccountId Id of the account that performs the liquidation
     * @param marketId Id of the market in which the liquidation is taking place
     * @param inputs The extra inputs required by the liquidation order
     *
     * Requirements:
     *
     * - `msg.sender` must be Core.
     *
     */
    function executeLiquidationOrder(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes calldata inputs
    ) external returns (bytes memory output);


    /**
     * @notice Decoded inputs and completes a position
     * @param accountId Id of the account that wants to complete a position
     * @param marketId Id of the market in which the account wants to complete a position
     * @param inputs The extra inputs required by the maker order
     *
     * Requirements:
     *
     * - `msg.sender` must be Core.
     *
     */
    function completeOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external returns (bytes memory output, int256 cashflowAmount);
}
