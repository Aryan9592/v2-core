// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { FullMath } from "../libraries/math/FullMath.sol";
import { FixedPoint128 } from "../libraries/math/FixedPoint128.sol";
import { LiquidityMath } from "../libraries/math/LiquidityMath.sol";
import { PositionBalances } from "../libraries/DataTypes.sol";

/**
 * @title Tracks LP positions
 */
library LPPosition {
    using LPPosition for LPPosition.Data;

    error LPPositionNotFound();

    struct Data {
        /**
         * @dev position's account id
         */
        uint128 id;
        /**
         * @dev position's account id
         */
        uint128 accountId;
        /**
         * @dev amount of liquidity per tick in this position
         */
        uint128 liquidity;
        /**
         * @dev lower tick boundary of the position
         */
        int24 tickLower;
        /**
         * @dev upper tick boundary of the position
         */
        int24 tickUpper;
        /**
         * @dev vamm trackers
         */
        PositionBalances updatedGrowthTrackers;
        /**
         * @dev trader balances
         */
        PositionBalances traderBalances;
    }

    /**
     * @dev Loads the LPPosition object for the given position Id
     */
    function load(uint128 id) private pure returns (Data storage position) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.LPPosition", id));
        assembly {
            position.slot := s
        }
    }

    /**
     * @dev Returns the position stored at the specified id. Reverts if no such position is found.
     */
    function exists(uint128 id) internal view returns (Data storage position) {
        position = load(id);

        if (position.id == 0) {
            revert LPPositionNotFound();
        }
    }

    /**
     * @dev Loads the LPPosition object for the given position Id or it creates one if it doesn't exist
     */
    function loadOrCreate(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper
    )
        internal
        returns (Data storage position)
    {
        uint128 positionId =
            uint128(uint256(keccak256(abi.encodePacked(accountId, marketId, maturityTimestamp, tickLower, tickUpper))));

        position = load(positionId);

        if (position.id == 0) {
            position.id = positionId;
            position.accountId = accountId;
            position.tickUpper = tickUpper;
            position.tickLower = tickLower;
        }

        return position;
    }

    /**
     * @dev Upadtes the position's trader balances
     */
    function updateTokenBalances(Data storage self, PositionBalances memory growthInsideX128) internal {
        PositionBalances memory deltas;
        if (self.liquidity > 0) {
            deltas = calculateTrackersDelta(self, growthInsideX128);
        }

        self.traderBalances.base += deltas.base;
        self.traderBalances.quote += deltas.quote;
        self.traderBalances.extraCashflow += deltas.extraCashflow;

        self.updatedGrowthTrackers = growthInsideX128;
    }

    /**
     * @dev Upadtes the position's liquidity
     */
    function updateLiquidity(Data storage self, int128 liquidityDelta) internal {
        self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
    }

    /**
     * @dev Returns the most up-to-date trader balances
     */
    function getUpdatedPositionBalances(
        Data memory self,
        PositionBalances memory growthInsideX128
    )
        internal
        pure
        returns (PositionBalances memory)
    {
        PositionBalances memory deltas;
        if (self.liquidity > 0) {
            deltas = calculateTrackersDelta(self, growthInsideX128);
        }

        return PositionBalances({
            base: self.traderBalances.base + deltas.base,
            quote: self.traderBalances.quote + deltas.quote,
            extraCashflow: self.traderBalances.extraCashflow + deltas.extraCashflow
        });
    }

    /**
     * @dev Computes the position balances delta based on the trackers
     */
    function calculateTrackersDelta(
        Data memory self,
        PositionBalances memory growthInsideX128
    )
        private
        pure
        returns (PositionBalances memory deltas)
    {
        deltas.base = FullMath.mulDivSigned(
            growthInsideX128.base - self.updatedGrowthTrackers.base, self.liquidity, FixedPoint128.Q128
        );

        deltas.quote = FullMath.mulDivSigned(
            growthInsideX128.quote - self.updatedGrowthTrackers.quote, self.liquidity, FixedPoint128.Q128
        );

        deltas.extraCashflow = FullMath.mulDivSigned(
            growthInsideX128.extraCashflow - self.updatedGrowthTrackers.extraCashflow,
            self.liquidity,
            FixedPoint128.Q128
        );
    }
}
