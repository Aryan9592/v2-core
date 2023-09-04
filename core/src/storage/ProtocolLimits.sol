/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Tracks protocol wide limits and restrictions
 */
library ProtocolLimits {

    struct Configuration {
        uint32 windowSize;
        UD60x18 tvlPercentageLimit;
    }

    struct Trackers {
        uint256 tvl;
        uint256 windowWithdrawals;
    }

    struct Data {
        Configuration config;
        Trackers trackers;
    }

    /**
     * @notice Emitted when the protocol limits configuration is created or updated
     * @param config The object with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event ProtocolLimitsConfigurationUpdated(Data config, uint256 blockTimestamp);

    /**
     * Thrown when protocol limits configuration was not set
     */
    error ProtocolLimitsNotConfigured();

    /**
     * @dev Loads the ProtocolLimits object.
     * @return config The ProtocolLimits object.
     */
    function load() private pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.ProtocolLimits"));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Returns the protocol limits data
     */
    function exists() internal view returns (Data storage config) {
        config = load();

        if (config.config.windowSize == 0) {
            revert ProtocolLimitsNotConfigured();
        }
    }

     /**
     * @dev Sets the protocol limits configuration
     * @param config The Configuration object with protocol limits configuration
     */
    function set(Configuration memory config) internal {
        Data storage storedConfig = load();
        storedConfig.config = config;

        emit ProtocolLimitsConfigurationUpdated(storedConfig, block.timestamp);
    }
}