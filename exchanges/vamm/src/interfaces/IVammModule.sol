// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { Tick } from "../libraries/ticks/Tick.sol";

import { LPPosition } from "../storage/LPPosition.sol";
import { DatedIrsVamm } from "../storage/DatedIrsVamm.sol";

/**
 * @title The interface for the VAMM module
 * @notice Interface that manages a VAMM's configuration
 */
interface IVammModule {
    /**
     * @notice Registers a new VAMM with the specified configurations and initializes the price
     */
    function createVamm(
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks,
        DatedIrsVamm.Immutable calldata config,
        DatedIrsVamm.Mutable calldata mutableConfig
    )
        external;

    /**
     * @notice Configures an existing VAMM
     * @dev Only configures mutable VAMM variables
     */
    function configureVamm(uint128 marketId, uint32 maturityTimestamp, DatedIrsVamm.Mutable calldata config) external;

    /**
     * @param marketId Id of the market for which we want to increase the number of observations
     * @param maturityTimestamp Timestamp at which the given market matures
     * @param observationCardinalityNext The desired minimum number of observations for the pool to store
     */
    function increaseObservationCardinalityNext(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint16 observationCardinalityNext
    )
        external;

    /**
     * @notice Returns vamm configuration
     */
    function getVammConfig(
        uint128 marketId,
        uint32 maturityTimestamp
    )
        external
        view
        returns (DatedIrsVamm.Immutable memory config, DatedIrsVamm.Mutable memory mutableConfig);

    /**
     * @param marketId Id of the market to look at
     * @param maturityTimestamp Timestamp at which the given market matures
     * @return tick The current tick of the market and maturity
     */
    function getVammTick(uint128 marketId, uint32 maturityTimestamp) external view returns (int24 tick);

    /**
     * @param marketId Id of the market to look at
     * @param maturityTimestamp Timestamp at which the given market matures
     * @param accountId Identifies the account id to look at
     * @return positionsInAccount The list of position ids associated with the account
     */
    function getVammPositionsInAccount(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (uint128[] memory positionsInAccount);

    /**
     * @param marketId Id of the market to look at
     * @param maturityTimestamp Timestamp at which the given market matures
     * @return observationIndex The index of the observation that was most recently written to the observations array
     * @return observationCardinality The number of populated elements in the oracle array
     * @return observationCardinalityNext The new length of the oracle array, independent of population
     */
    function getVammObservationInfo(
        uint128 marketId,
        uint32 maturityTimestamp
    )
        external
        view
        returns (uint16, uint16, uint16);

    /**
     * @param positionId Id of the position to look at
     * @return position The position data
     */
    function getVammPosition(uint128 positionId) external view returns (LPPosition.Data memory);
}
