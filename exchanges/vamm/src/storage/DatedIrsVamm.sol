// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { AccountBalances } from "../libraries/vamm-utils/AccountBalances.sol";
import { Swap } from "../libraries/vamm-utils/Swap.sol";
import { LP } from "../libraries/vamm-utils/LP.sol";
import { VammConfiguration } from "../libraries/vamm-utils/VammConfiguration.sol";
import { VammCustomErrors } from "../libraries/errors/VammCustomErrors.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Connects external contracts that implement the `IVAMM` interface to the protocol.
 *
 */
library DatedIrsVamm {
    /// @dev Internal, frequently-updated state of the VAMM, which is compressed into one storage slot.
    struct Data {
        /// @dev vamm config set at initialization, can't be modified after creation
        VammConfiguration.Immutable immutableConfig;
        /// @dev configurable vamm config
        VammConfiguration.Mutable mutableConfig;
        /// @dev vamm state frequently-updated
        VammConfiguration.State vars;
        /// @dev Equivalent to getSqrtRatioAtTick(minTickAllowed)
        uint160 minSqrtRatioAllowed;
        /// @dev Equivalent to getSqrtRatioAtTick(maxTickAllowed)
        uint160 maxSqrtRatioAllowed;
    }

    struct SwapParams {
        /// @dev The amount of the swap in base tokens, which implicitly configures the swap 
        ///      as exact input (positive), or exact output (negative)
        int256 amountSpecified;
        /// @dev The Q64.96 sqrt price limit. If !isFT, the price cannot be less than this
        uint160 sqrtPriceLimitX96;
        /// @dev Mark price used to compute dynamic price limits
        UD60x18 markPrice;
        /// @dev Fixed Mark Price Band applied to the mark price to compute the dynamic price limits
        UD60x18 markPriceBand;
    }

    struct UnfilledBalances {
        uint256 baseLong;
        uint256 baseShort;
        uint256 quoteLong;
        uint256 quoteShort;
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id.
     */
    function load(uint256 id) internal pure returns (Data storage irsVamm) {
        if (id == 0) {
            revert VammCustomErrors.IRSVammNotFound(0);
        }
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSVamm", id));
        assembly {
            irsVamm.slot := s
        }
    }

    /**
     * @dev Returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function exists(uint256 id) internal view returns (Data storage irsVamm) {
        irsVamm = load(id);
        if (irsVamm.immutableConfig.maturityTimestamp == 0) {
            revert VammCustomErrors.IRSVammNotFound(id);
        }
    }

    /**
     * @dev Finds the vamm id using market id and maturity and
     * returns the vamm stored at the specified vamm id. Reverts if no such VAMM is found.
     */
    function loadByMaturityAndMarket(uint128 marketId, uint32 maturityTimestamp) internal view returns (Data storage irsVamm) {
        uint256 id = uint256(keccak256(abi.encodePacked(marketId, maturityTimestamp)));
        irsVamm = exists(id);
    }

    function vammSwap(
        DatedIrsVamm.Data storage self,
        DatedIrsVamm.SwapParams memory params
    ) internal returns (int256 /* quoteTokenDelta */, int256 /* baseTokenDelta */) {
        return Swap.vammSwap(self, params);
    }

    /**
     * @notice Executes a dated maker order that provides liquidity to (or removes liquidty from) this VAMM
     * @param accountId Id of the `Account` with which the lp wants to provide liqudiity
     * @param tickLower Lower tick of the range order
     * @param tickUpper Upper tick of the range order
     * @param liquidityDelta Liquidity to add (positive values) or remove (negative values) witin the tick range
     */
    function executeDatedMakerOrder(
        DatedIrsVamm.Data storage self,
        uint128 accountId,
        uint128 marketId,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
    internal {
        LP.executeDatedMakerOrder(
            self,
            accountId,
            marketId,
            tickLower,
            tickUpper,
            liquidityDelta
        );
    }
    
    /// @notice For a given LP account, how much liquidity is available to trade in each direction.
    /// @param accountId The LP account. All positions within the account will be considered.
    /// @return unfilled The unfilled base and quote balances
    function getAccountUnfilledBalances(DatedIrsVamm.Data storage self, uint128 accountId)
    internal
    view
    returns (DatedIrsVamm.UnfilledBalances memory) {
        return AccountBalances.getAccountUnfilledBalances(self, accountId);
    }

    /// @dev For a given LP posiiton, how much of it is already traded and what are base and 
    /// quote tokens representing those exiting trades?
    function getAccountFilledBalances(DatedIrsVamm.Data storage self,uint128 accountId)
    internal
    view
    returns (int256 /* baseBalancePool */, int256 /* quoteBalancePool */) {
        return AccountBalances.getAccountFilledBalances(self, accountId);
    }
}
