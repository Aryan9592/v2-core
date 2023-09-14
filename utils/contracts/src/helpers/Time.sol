pragma solidity >=0.8.19;

import {UD60x18, toUD60x18, ud} from "@prb/math/UD60x18.sol";

library Time {
    using {toUD60x18} for uint256;

    uint256 internal constant SECONDS_IN_YEAR = 31536000;

    /// @dev Returns the block timestamp truncated to 32 bits, checking for overflow.
    function blockTimestampTruncated() internal view returns (uint32) {
        return timestampAsUint32(block.timestamp);
    }

    function timestampAsUint32(uint256 _timestamp) internal pure returns (uint32 timestamp) {
        require((timestamp = uint32(_timestamp)) == _timestamp, "TSOFLOW");
    } 

    function timeDeltaAnnualized(uint32 fromTimestamp, uint32 toTimestamp) internal pure returns (UD60x18 _timeDeltaAnnualized) {
        _timeDeltaAnnualized = (uint256(toTimestamp) -fromTimestamp).toUD60x18().div(SECONDS_IN_YEAR.toUD60x18());
    }

    function timeDeltaAnnualized(uint32 toTimestamp) internal view returns (UD60x18 _timeDeltaAnnualized) {
        if (toTimestamp > blockTimestampTruncated()) {
            _timeDeltaAnnualized = timeDeltaAnnualized(timestampAsUint32(block.timestamp), toTimestamp);
        }
    }
}
