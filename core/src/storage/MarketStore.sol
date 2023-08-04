/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./Market.sol";

/**
 * @title Tracks Market id 
 */
library MarketStore {
    bytes32 private constant _SLOT_MARKET_STORE = keccak256(abi.encode("xyz.voltz.MarketStore"));

    struct Data {
        /**
         * @dev Keeps track of the last Market id created.
         * Used for easily creating new Markets.
         */
        uint128 lastCreatedMarketId;
    }

    /**
     * @dev Returns the singleton Market store of the system.
     */
    function getMarketStore() internal pure returns (Data storage marketStore) {
        bytes32 s = _SLOT_MARKET_STORE;
        assembly {
            marketStore.slot := s
        }
    }

    function advanceMarketId() internal returns (uint128) {
        Data storage marketStore = getMarketStore();
        marketStore.lastCreatedMarketId += 1;
        return marketStore.lastCreatedMarketId;
    }
}
