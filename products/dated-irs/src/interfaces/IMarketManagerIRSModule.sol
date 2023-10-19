/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { MarketManagerConfiguration } from "../storage/MarketManagerConfiguration.sol";
import { FilledBalances } from "../libraries/DataTypes.sol";

import { IMarketManager } from "@voltz-protocol/core/src/interfaces/external/IMarketManager.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/// @title Interface of a dated irs market
interface IMarketManagerIRSModule is IMarketManager {
    error MissingBatchMatchOrderImplementation();

    event MarketManagerConfigured(MarketManagerConfiguration.Data config, uint256 blockTimestamp);

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

    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (FilledBalances memory);

    // todo: add natspec
    function propagateADLOrder(uint128 accountId, uint128 marketId, uint32 maturityTimestamp, bool isLong) external;

    function getPercentualSlippage(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 annualizedExposureWad
    )
        external
        view
        returns (UD60x18);
}
