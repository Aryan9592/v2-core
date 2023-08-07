/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Represents Oracle Manager
 */
library OracleManager {
    bytes32 private constant _SLOT_ORACLE_MANAGER = keccak256(abi.encode("xyz.voltz.OracleManager"));

    /**
     * @notice Emitted when the oracle manager is created or updated
     * @param oracleManager The object with the newly updated details.
     * @param blockTimestamp The current block timestamp.
     */
    event OracleManagerUpdated(Data oracleManager, uint256 blockTimestamp);

    struct Data {
        /**
         * @dev The oracle manager address.
         */
        address oracleManagerAddress;
    }

    /**
     * @dev Loads the singleton storage info about the oracle manager.
     */
    function load() internal pure returns (Data storage oracleManager) {
        bytes32 s = _SLOT_ORACLE_MANAGER;
        assembly {
            oracleManager.slot := s
        }
    }

    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.oracleManagerAddress = config.oracleManagerAddress;

        emit OracleManagerUpdated(storedConfig, block.timestamp);
    }
}