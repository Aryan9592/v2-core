//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {FullMath} from "../libraries/math/FullMath.sol";
import {FixedPoint128} from "../libraries/math/FixedPoint128.sol";
import {LiquidityMath} from "../libraries/math/LiquidityMath.sol";

/**
 * @title Tracks LP positions
 */
library LPPosition {
    using LPPosition for LPPosition.Data;

    error PositionNotFound();

    struct VammTrackers {
        /** 
        * @dev quote token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 quoteTokenUpdatedGrowth;
        /** 
        * @dev variable token growth per unit of liquidity as of the last update to liquidity or fixed/variable token balance
        */
        int256 baseTokenUpdatedGrowth;
        /** 
        * @dev current Quote Token balance of the position, 1 quote token can be redeemed for 
        * 1% APY * (annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 quoteTokenAccumulated;
        /** 
        * @dev current Variable Token Balance of the position, 
        * 1 variable token can be redeemed for underlyingPoolAPY*(annualised amm term) at the maturity of the amm
        * assuming 1 token worth of notional "deposited" in the underlying pool at the inception of the amm
        * can be negative/positive/zero
        */
        int256 baseTokenAccumulated;
    }

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
        VammTrackers trackers;
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

    function updateTrackers(
        Data storage self,
        int256 trackerQuoteTokenUpdatedGrowth,
        int256 trackerBaseTokenUpdatedGrowth,
        int256 deltaTrackerQuoteTokenAccumulated,
        int256 deltaTrackerBaseTokenAccumulated
    ) internal 
    {
        self.trackers.quoteTokenUpdatedGrowth = trackerQuoteTokenUpdatedGrowth;
        self.trackers.baseTokenUpdatedGrowth = trackerBaseTokenUpdatedGrowth;
        self.trackers.quoteTokenAccumulated += deltaTrackerQuoteTokenAccumulated;
        self.trackers.baseTokenAccumulated += deltaTrackerBaseTokenAccumulated;
    }

    function updateLiquidity(Data storage self, int128 liquidityDelta) internal {
        self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
    }

    function getUpdatedPositionBalances(
        Data memory self,
        int256 quoteTokenGrowthInsideX128,
        int256 baseTokenGrowthInsideX128
    ) internal pure returns (int256, int256) 
    {
        (int256 quoteTokenDelta, int256 baseTokenDelta) = calculateFixedAndVariableDelta(
            self,
            quoteTokenGrowthInsideX128,
            baseTokenGrowthInsideX128
        );

        return (
            self.trackers.quoteTokenAccumulated + quoteTokenDelta,
            self.trackers.baseTokenAccumulated + baseTokenDelta
        );
    }

    /// @notice Returns Fixed and Variable Token Deltas
    /// @param self position info struct represeting a liquidity provider
    /// @param quoteTokenGrowthInsideX128 quote token growth per unit of liquidity as of now (in wei)
    /// @param baseTokenGrowthInsideX128 variable token growth per unit of liquidity as of now (in wei)
    /// @return quoteTokenDelta = (quoteTokenGrowthInside-quoteTokenGrowthInsideLast) * liquidity of a position
    /// @return baseTokenDelta = (baseTokenGrowthInside-baseTokenGrowthInsideLast) * liquidity of a position
    function calculateFixedAndVariableDelta(
        Data memory self,
        int256 quoteTokenGrowthInsideX128,
        int256 baseTokenGrowthInsideX128
    )
        internal
        pure
        returns (int256 quoteTokenDelta, int256 baseTokenDelta)
    {
        int256 quoteTokenGrowthInsideDeltaX128 = quoteTokenGrowthInsideX128 -
            self.trackers.quoteTokenUpdatedGrowth;

        quoteTokenDelta = FullMath.mulDivSigned(
            quoteTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );

        int256 baseTokenGrowthInsideDeltaX128 = baseTokenGrowthInsideX128 -
                self.trackers.baseTokenUpdatedGrowth;

        baseTokenDelta = FullMath.mulDivSigned(
            baseTokenGrowthInsideDeltaX128,
            self.liquidity,
            FixedPoint128.Q128
        );
    }
}
