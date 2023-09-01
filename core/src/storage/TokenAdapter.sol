/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Represents Token Adapter
 */
library TokenAdapter {
    bytes32 private constant _SLOT_TOKEN_ADAPTER = keccak256(abi.encode("xyz.voltz.TokenAdapter"));

    /**
     * @notice Emitted when the token adapter is created or updated
     * @param tokenAdapter The object with the newly updated details.
     * @param blockTimestamp The current block timestamp.
     */
    event TokenAdapterUpdated(Data tokenAdapter, uint256 blockTimestamp);
    
    /**
     * Thrown when token adapter is not configured
     */
    error TokenAdapterNotConfigured();

    struct Data {
        /**
         * @dev The token adapter address.
         */
        address tokenAdapterAddress;
    }

    /**
     * @dev Loads the singleton storage info about the token adapter.
     */
    function load() private pure returns (Data storage tokenAdapter) {
        bytes32 s = _SLOT_TOKEN_ADAPTER;
        assembly {
            tokenAdapter.slot := s
        }
    }

    /**
     * @dev Returns the token adapter storage info.
     */
    function exists() internal view returns (Data storage tokenAdapter) {
        tokenAdapter = load();

        if (tokenAdapter.tokenAdapterAddress == address(0)) {
            revert TokenAdapterNotConfigured();
        }
    }

    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.tokenAdapterAddress = config.tokenAdapterAddress;

        emit TokenAdapterUpdated(storedConfig, block.timestamp);
    }
}