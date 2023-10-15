// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.13;

import { FeatureFlag } from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

/// @title Pool configuration
library PoolConfiguration {
    bytes32 private constant _PAUSER_FEATURE_FLAG = "pauser";

    struct Data {
        address marketManagerAddress;
        uint256 makerPositionsPerAccountLimit;
    }

    /**
     * @dev Loads the pool configuration object
     */
    function load() internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.PoolConfiguration"));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Sets the pool configuration
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();

        storedConfig.marketManagerAddress = config.marketManagerAddress;
        storedConfig.makerPositionsPerAccountLimit = config.makerPositionsPerAccountLimit;
    }

    /**
     * @dev Reverts id the pool is paused
     */
    function whenNotPaused() internal view {
        FeatureFlag.ensureAccessToFeature(_PAUSER_FEATURE_FLAG);
    }
}
