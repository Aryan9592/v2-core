//SPDX-License-Identifier: MIT

pragma solidity >=0.8.13;

import { PositionBalances } from "./DataTypes.sol";
import { DatedIrsVamm } from "../storage/DatedIrsVamm.sol";

library Events {
    /// @dev emitted when vamm configurations are updated
    event VammConfigUpdated(
        uint128 marketId, uint32 maturityTimestamp, DatedIrsVamm.Mutable config, uint256 blockTimestamp
    );

    /// @dev emitted when a new vamm is created and initialized
    event VammCreated(
        int24 tick, DatedIrsVamm.Immutable config, DatedIrsVamm.Mutable mutableConfig, uint256 blockTimestamp
    );

    /// @dev emitted after a successful swap transaction
    event Swap(
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        int256 desiredBaseAmount,
        uint160 sqrtPriceLimitX96,
        PositionBalances tokenDeltas,
        uint256 blockTimestamp
    );

    /// @dev emitted after a successful mint or burn of liquidity on a given LP position
    event LiquidityChange(
        uint128 marketId,
        uint32 maturityTimestamp,
        address sender,
        uint128 indexed accountId,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        int128 liquidityDelta,
        uint256 blockTimestamp
    );

    event VAMMPriceChange(
        uint128 indexed marketId, uint32 indexed maturityTimestamp, int24 tick, uint256 blockTimestamp
    );
}
