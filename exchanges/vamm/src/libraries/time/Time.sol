// SPDX-License-Identifier: Apache-2.0

pragma solidity >=0.8.13;
import { UD60x18, convert } from "@prb/math/UD60x18.sol";

library Time {
    uint256 internal constant SECONDS_IN_A_DAY = 86400;

    /// @notice Calculate block.timestamp to wei precision
    /// @return Current timestamp in wei-seconds (1/1e18)
    function blockTimestampScaled() internal view returns (UD60x18) {
        // solhint-disable-next-line not-rely-on-time
        return convert(block.timestamp);
    }

    /// @dev Returns the block timestamp truncated to 32 bits, checking for overflow.
    function blockTimestampTruncated() internal view returns (uint32) {
        return timestampAsUint32(block.timestamp);
    }

    function timestampAsUint32(uint256 _timestamp)
        internal
        pure
        returns (uint32 timestamp)
    {
        require((timestamp = uint32(_timestamp)) == _timestamp, "TSOFLOW");
    }

    function isCloseToMaturityOrBeyondMaturity(uint32 maturityTimestamp)
        internal
        view
        returns (bool vammInactive)
    {
        return
            block.timestamp + SECONDS_IN_A_DAY >=
            maturityTimestamp;
    }

    /// @dev Modifier that ensures new LP positions cannot be minted after one day before the maturity of the vamm
    /// @dev also ensures new swaps cannot be conducted after one day before maturity of the vamm
    function checkCurrentTimestampMaturityTimestampDelta(uint32 maturityTimestamp) internal view {
        if (isCloseToMaturityOrBeyondMaturity(maturityTimestamp)) {
            revert("closeToOrBeyondMaturity");
        }
    }
}
