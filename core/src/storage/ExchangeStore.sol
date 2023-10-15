/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;



/**
 * @title Tracks Exchange id
 */
// todo: lots of similarities with MarketStore, can we simplify?
library ExchangeStore {
    // todo: replace xyz.voltz with reya.voltz (in all storage pointers)?
    bytes32 private constant _SLOT_EXCHANGE_STORE = keccak256(abi.encode("xyz.voltz.ExchangeStore"));

    /**
     * @notice Emitted when the exchange store is created or updated
     * @param exchangeStore The object with the newly updated details.
     * @param blockTimestamp The current block timestamp.
     */
    event ExchangeStoreUpdated(Data exchangeStore, uint256 blockTimestamp);

    struct Data {
        /**
         * @dev Keeps track of the last Exchange id created.
         * Used for easily creating new Exchanges.
         */
        uint128 lastCreatedExchangeId;
    }

    /**
     * @dev Returns the singleton Exchange store of the system.
     */
    function getExchangeStore() internal pure returns (Data storage exchangeStore) {
        bytes32 s = _SLOT_EXCHANGE_STORE;
        assembly {
            exchangeStore.slot := s
        }
    }

    function advanceExchangeId() internal returns (uint128) {
        Data storage exchangeStore = getExchangeStore();
        exchangeStore.lastCreatedExchangeId += 1;

        emit ExchangeStoreUpdated(exchangeStore, block.timestamp);

        return exchangeStore.lastCreatedExchangeId;
    }
}
