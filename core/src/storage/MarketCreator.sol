/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./Market.sol";

/**
 * @title Encapsulates Market creation logic
 */
library MarketCreator {
    bytes32 private constant _SLOT_Market_CREATOR = keccak256(abi.encode("xyz.voltz.MarketCreator"));

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
        bytes32 s = _SLOT_Market_CREATOR;
        assembly {
            marketStore.slot := s
        }
    }

    /**
     * @dev Given an external contract address representing an `IMarket`, creates a new id for the Market, and tracks it
     * internally in the protocol.
     *
     * The id used to track the Market will be automatically assigned by the protocol according to the last id used.
     *
     * Note: If an external `IMarket` contract tracks several Market ids, this function should be called for each Market it
     * tracks, resulting in multiple ids for the same address.
     * For example if a given Market works across maturities, each maturity internally will be represented as a unique Market id
     */
    function create(address marketManagerAddress, string memory name, address owner)
        internal
        returns (Market.Data storage market)
    {
        Data storage marketStore = getMarketStore();

        uint128 id = marketStore.lastCreatedMarketId + 1;
        market = Market.load(id);
    
        market.id = id;
        market.marketManagerAddress = marketManagerAddress;
        market.name = name;
        market.owner = owner;
        marketStore.lastCreatedMarketId = id;
    }
}
