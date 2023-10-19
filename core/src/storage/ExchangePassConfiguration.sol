/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Tracks Reya Exchange Pass NFT and provides helpers to interact with it
 */
library ExchangePassConfiguration {

    struct Data {
        address exchangePassNFTAddress;
    }

    /**
     * Thrown when exchange pass configuration was not set
     */
    error ExchangePassNotConfigured();

    /**
     * @notice Emitted when the exchange pass configuration is created or updated
     * @param config The object with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event ExchangePassConfigurationUpdated(Data config, uint256 blockTimestamp);

    /**
     * @dev Loads the ExchangePassConfiguration object.
     * @return config The ExchangePassConfiguration object.
     */
    function load() private pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.ExchangePassConfiguration"));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Returns the exchange pass configuration
     */
    function exists() internal view returns (Data storage config) {
        config = load();

        if (config.exchangePassNFTAddress == address(0)) {
            revert ExchangePassNotConfigured();
        }
    }

    /**
     * @dev Sets the exchange pass configuration
     * @param config The ExchangePassConfiguration object with exchange pass nft address
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.exchangePassNFTAddress = config.exchangePassNFTAddress;

        emit ExchangePassConfigurationUpdated(storedConfig, block.timestamp);
    }

}