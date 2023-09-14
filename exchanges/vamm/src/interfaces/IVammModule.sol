// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { LPPosition } from "../storage/LPPosition.sol";
import { DatedIrsVamm } from "../storage/DatedIrsVamm.sol";
import { Oracle } from "../storage/Oracle.sol";
import { Tick } from "../libraries/ticks/Tick.sol";

interface IVammModule {
  /// @dev Emitted when vamm configurations are updated
  event VammConfigUpdated(
      uint128 marketId,
      uint32 maturityTimestamp,
      DatedIrsVamm.Mutable config,
      uint256 blockTimestamp
  );

  /// @dev Emitted when a new vamm is created and initialized
  event VammCreated(
      int24 tick,
      DatedIrsVamm.Immutable config,
      DatedIrsVamm.Mutable mutableConfig,
      uint256 blockTimestamp
  );

  /**
    * @notice registers a new vamm with the specified configurationsa and initializes the price
    */
  function createVamm(
    uint160 sqrtPriceX96, 
    uint32[] memory times, 
    int24[] memory observedTicks, 
    DatedIrsVamm.Immutable calldata config, 
    DatedIrsVamm.Mutable calldata mutableConfig
  ) external;

  /**
    * @notice Configures an existing vamm 
    * @dev Only configures mutable vamm variables
    */
  function configureVamm(
    uint128 marketId,
    uint32 maturityTimestamp,
    DatedIrsVamm.Mutable calldata config
  ) external;

  /**
    * @param marketId Id of the market for which we want to increase the number of observations
    * @param maturityTimestamp Timestamp at which the given market matures
    * @param observationCardinalityNext The desired minimum number of observations for the pool to store
    */
  function increaseObservationCardinalityNext(uint128 marketId, uint32 maturityTimestamp, uint16 observationCardinalityNext)
    external;

  ///////////// GETTERS /////////////

  /**
    * @notice Returns vamm configuration
    */
  function getVammConfig(uint128 marketId, uint32 maturityTimestamp)
    external view returns (
      DatedIrsVamm.Immutable memory config,
      DatedIrsVamm.Mutable memory mutableConfig
    );

  function getVammSqrtPriceX96(uint128 marketId, uint32 maturityTimestamp)
    external view returns (uint160 sqrtPriceX96);

  function getVammTick(uint128 marketId, uint32 maturityTimestamp)
    external view returns (int24 tick);

  function getVammTickInfo(uint128 marketId, uint32 maturityTimestamp, int24 tick)
    external view returns (Tick.Info memory tickInfo);

  function getVammTickBitmap(uint128 marketId, uint32 maturityTimestamp, int16 wordPosition)
    external view returns (uint256);
  
  function getVammLiquidity(uint128 marketId, uint32 maturityTimestamp)
    external view returns (uint128 liquidity);

  function getVammPositionsInAccount(uint128 marketId, uint32 maturityTimestamp, uint128 accountId)
    external view returns (uint128[] memory positionsInAccount);

  function getVammTrackerQuoteTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp)
    external view returns (int256 trackerQuoteTokenGrowthGlobalX128);
  
  function getVammTrackerBaseTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp)
    external view returns (int256 trackerBaseTokenGrowthGlobalX128);

  function getVammObservationInfo(uint128 marketId, uint32 maturityTimestamp)
      external view returns (uint16, uint16, uint16);

  function getVammObservations(uint128 marketId, uint32 maturityTimestamp)
      external view returns (Oracle.Observation[65535] memory);

  function getVammObservationAtIndex(uint16 index, uint128 marketId, uint32 maturityTimestamp)
        external view returns (Oracle.Observation memory);

  function getVammPosition(uint128 positionId)
        external view returns (LPPosition.Data memory);
}