/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


/**
 * @title Tracks Reya Access Pass NFT and provides helpers to interact with it
 */
library AccessPassConfiguration {

    struct Data {
        address accessPassNFTAddress;
    }

    /**
     * Thrown when access pass configuration was not set
     */
    error AccessPassNotConfigured();

    /**
     * @notice Emitted when the access pass configuration is created or updated
     * @param config The object with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event AccessPassConfigurationUpdated(Data config, uint256 blockTimestamp);

    /**
     * @dev Loads the AccessPassConfiguration object.
     * @return config The AccessPassConfiguration object.
     */
    function load() private pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.AccessPassConfiguration"));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Returns the access pass configuration
     */
    function exists() internal view returns (Data storage config) {
        config = load();

        if (config.accessPassNFTAddress == address(0)) {
            revert AccessPassNotConfigured();
        }
    }

     /**
     * @dev Sets the access pass configuration
     * @param config The AccessPassConfiguration object with access pass nft address
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.accessPassNFTAddress = config.accessPassNFTAddress;

        emit AccessPassConfigurationUpdated(storedConfig, block.timestamp);
    }
}