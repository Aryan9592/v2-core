// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import { FeatureFlag } from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

/// @title Pool configuration
library PoolConfiguration {
    bytes32 private constant _PAUSER_FEATURE_FLAG = "pauser";

    struct Data {
        address marketManagerAddress;
        uint256 makerPositionsPerAccountLimit;
    }

    function load() internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.PoolConfiguration"));
        assembly {
            config.slot := s
        }
    }

    function set(Data memory config) internal {
        Data storage storedConfig = load();

        storedConfig.marketManagerAddress = config.marketManagerAddress;
        storedConfig.makerPositionsPerAccountLimit = config.makerPositionsPerAccountLimit;
    }

    function whenNotPaused() internal view {
        FeatureFlag.ensureAccessToFeature(_PAUSER_FEATURE_FLAG);
    }
}
