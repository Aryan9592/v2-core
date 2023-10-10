//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;


import { FullMath } from "../libraries/math/FullMath.sol";
import { FixedPoint128 } from "../libraries/math/FixedPoint128.sol";
import { LiquidityMath } from "../libraries/math/LiquidityMath.sol";
import { VammHelpers } from "../libraries/vamm-utils/VammHelpers.sol";
import { MTMObservation, FilledBalances, PositionBalances } from "../libraries/DataTypes.sol";

import { TraderPosition } from "@voltz-protocol/products-dated-irs/src/libraries/TraderPosition.sol";


/**
 * @title Tracks LP positions
 */
library LPPosition {
    using LPPosition for LPPosition.Data;

    error PositionNotFound();

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
        FilledBalances updatedGrowthTrackers;
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

    function exists(uint128 id) internal view returns (Data storage position) {
        position = load(id);

        if (position.id == 0) {
            revert PositionNotFound();
        }
    }

    function loadOrCreate(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper
    ) internal returns (Data storage position)
    {
        uint128 positionId = uint128(uint256(keccak256(
            abi.encodePacked(accountId, marketId, maturityTimestamp, tickLower, tickUpper)
        )));

        position = load(positionId);

        if (position.id == 0) {
            position.id = positionId;
            position.accountId = accountId;
            position.tickUpper = tickUpper;
            position.tickLower = tickLower;
        }

        return position;
    }

    function updateTokenBalances(
        Data storage self,
        uint128 marketId,
        uint32 maturityTimestamp,
        FilledBalances memory growthInsideX128
    ) internal {
        FilledBalances memory deltas;
        if (self.liquidity > 0) {
            deltas = calculateTrackersDelta(self, growthInsideX128);
        }

        self.updatedGrowthTrackers = growthInsideX128;

        MTMObservation memory newObservation = 
            VammHelpers.getNewMTMTimestampAndRateIndex(marketId, maturityTimestamp);

        TraderPosition.updateBalances(
            self.traderBalances,
            deltas.base,
            deltas.quote,
            newObservation
        );
        
        self.traderBalances.accruedInterest += deltas.accruedInterest;
    }

    function updateLiquidity(Data storage self, int128 liquidityDelta) internal {
        self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
    }

    function getUpdatedPositionBalances(
        Data memory self,
        uint128 marketId,
        uint32 maturityTimestamp,
        FilledBalances memory growthInsideX128
    ) internal view returns (FilledBalances memory) 
    {
        FilledBalances memory deltas;
        if (self.liquidity > 0) {
            deltas = calculateTrackersDelta(self, growthInsideX128);
        }

        MTMObservation memory newObservation = 
            VammHelpers.getNewMTMTimestampAndRateIndex(marketId, maturityTimestamp);

        PositionBalances memory updatedPosition = TraderPosition.getUpdatedBalances(
            self.traderBalances,
            deltas.base,
            deltas.quote,
            newObservation
        );
        
        return FilledBalances({
            base: updatedPosition.base,
            quote: updatedPosition.quote,
            accruedInterest: updatedPosition.accruedInterest + deltas.accruedInterest
        });
    }

    function calculateTrackersDelta(
        Data memory self,
        FilledBalances memory growthInsideX128
    )
        private
        pure
        returns (FilledBalances memory deltas)
    {
        int256 baseTokenGrowthInsideDeltaX128 = growthInsideX128.base -
            self.updatedGrowthTrackers.base;

        deltas.base = FullMath.mulDivSigned(
            baseTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );

        int256 quoteTokenGrowthInsideDeltaX128 = growthInsideX128.quote -
            self.updatedGrowthTrackers.quote;

        deltas.quote = FullMath.mulDivSigned(
            quoteTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );

        int256 accruedInterestGrowthInsideDeltaX128 = growthInsideX128.accruedInterest -
            self.updatedGrowthTrackers.accruedInterest;

        deltas.accruedInterest = FullMath.mulDivSigned(
            accruedInterestGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );
    }
}
