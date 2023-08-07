/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/core/src/interfaces/external/IMarketManager.sol";
import "../storage/MarketManagerConfiguration.sol";

/// @title Interface of a dated irs market
interface IMarketManagerIRSModule is IMarketManager {
    event MarketManagerConfigured(MarketManagerConfiguration.Data config, uint256 blockTimestamp);

    struct TakerOrderParams {
        uint128 accountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmount;
        uint160 priceLimit;
    }

    /**
     * @notice Emitted when a taker order of the account token with id `accountId` is initiated.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param collateralType The address of the collateral.
     * @param executedBaseAmount The executed base amount of the order.
     * @param executedQuoteAmount The executed quote amount of the order.
     * @param annualizedNotionalAmount The annualized base of the order.
     * @param blockTimestamp The current block timestamp.
     */
    event TakerOrder(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        address collateralType,
        int256 executedBaseAmount,
        int256 executedQuoteAmount,
        int256 annualizedNotionalAmount,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when a position is settled.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param collateralType The address of the collateral.
     * @param blockTimestamp The current block timestamp.
     */
    event DatedIRSPositionSettled(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        address collateralType,
        int256 settlementCashflowInQuote,
        uint256 blockTimestamp
    );

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    // process taker and maker orders & single pool

    /**
     * @notice Returns the address that owns a given account, as recorded by the protocol.
     * @param accountId Id of the account that wants to settle
     * @param marketId Id of the market in which the account wants to settle (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity timestamp of the market in which the account wants to settle
     */
    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) external;

    /**
     * @notice Initiates a taker order for a given account by consuming liquidity provided by the pool linked to this market manager
     * @dev Initially a single pool is connected to a single market singleton, however, that doesn't need to be the case in the future
     * params accountId Id of the account that wants to initiate a taker order
     * params marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * params maturityTimestamp Maturity timestamp of the market in which the account wants to initiate a taker order
     * params priceLimit The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
     * params baseAmount Amount of notional that the account wants to trade in either long (+) or short (-) direction depending on
     * sign
     */
    function initiateTakerOrder(TakerOrderParams memory params)
        external
        returns (int256 executedBaseAmount, int256 executedQuoteAmount, uint256 fee, Account.MarginRequirement memory mr);

    /**
     * @notice Creates or updates the configuration for the given market manager.
     * @param config The MarketConfiguration object describing the new configuration.
     *
     * Requirements:
     *
     * - `msg.sender` must be the owner of the system.
     *
     * Emits a {MarketManagerConfigured} event.
     *
     */
    function configureMarketManager(MarketManagerConfiguration.Data memory config) external;

    /**
     * @notice Propagates maker order to core to check margin requirements
     * @param accountId Id of the account that wants to initiate a taker order
     * @param marketId Id of the market in which the account wants to initiate a taker order (e.g. 1 for aUSDC lend)
     * @param maturityTimestamp Maturity of the market's pool in which the account want to initiate a taker order
     * @param baseAmount The base amount of the order
     */
    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount
    ) external returns (uint256 fee, Account.MarginRequirement memory mr);

    /**
     * @notice Returns core proxy address from MarketManagerConfigruation
     */
    function getCoreProxyAddress() external returns (address);
}
