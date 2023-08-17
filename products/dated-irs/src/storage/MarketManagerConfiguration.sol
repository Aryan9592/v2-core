/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Tracks configurations for the Market Managers
 * note Enables the owner of the MarketManagerProxy to configure the pool address the market manager is linked to
 */
library MarketManagerConfiguration {
    bytes32 private constant _SLOT_MARKET_MANAGER_CONFIGURATION = keccak256(abi.encode("xyz.voltz.MarketManagerConfiguration"));

    struct Data {
        /**
         * @dev Address of the core proxy
         */
        address coreProxy;

        // todo: revise the fact that pool address is per market manager and not per market

        /**
         * @dev Address of the pool address the market manager is linked to
         */
        address poolAddress;
    }

    /**
     * @dev Loads the MarketManagerConfiguration object
     * @return marketManagerConfig The MarketManagerConfiguration object.
     */
    function load() internal pure returns (Data storage marketManagerConfig) {
        bytes32 s = _SLOT_MARKET_MANAGER_CONFIGURATION;
        assembly {
            marketManagerConfig.slot := s
        }
    }

    /**
     * @dev Configures a market manager
     * @param config The MarketManagerConfiguration object with all the settings for the market manager being configured.
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();

        //todo: check interface id of pool address (AB)

        storedConfig.coreProxy = config.coreProxy;
        storedConfig.poolAddress = config.poolAddress;
    }

    function getPoolAddress() internal view returns (address storedPoolAddress) {
        Data storage storedConfig = load();
        storedPoolAddress = storedConfig.poolAddress;
    }

    function getCoreProxyAddress() internal view returns (address storedProxyAddress) {
        Data storage storedConfig = load();
        storedProxyAddress = storedConfig.coreProxy;
    }
}
