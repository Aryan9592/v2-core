/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./ExchangeStore.sol";

library Exchange {

    /**
     * @dev Thrown when an exchange cannot be found.
     */
    error ExchangeNotFound(uint128 exchangeId);

    /**
     * @notice Emitted when a exchange is created or updated
     * @param exchange The object with the newly updated details.
     * @param blockTimestamp The current block timestamp.
     */
    event ExchangeUpdated(Exchange.Data exchange, uint256 blockTimestamp);

    struct Data {

        /**
         * @dev Numeric identifier for the exchange. Must be unique.
         * @dev There cannot be an exchange with id zero (See ExchangeCreator.create()). Id zero is used as a null market reference.
         */
        uint128 id;

        /**
         * @dev Exchange Fee Collector Account Id
         */
        uint128 exchangeFeeCollectorAccountId;

    }

    function create(uint128 exchangeFeeCollectorAccountId) internal returns (Data storage exchange) {
        uint128 id = ExchangeStore.advanceExchangeId();
        exchange = load(id);
        exchange.id = id;
        exchange.exchangeFeeCollectorAccountId = exchangeFeeCollectorAccountId;

        emit ExchangeUpdated(exchange, block.timestamp);

    }

    /**
     * @dev Returns the exchange stored at the specified exchange id.
     */
    function load(uint128 id) private pure returns (Data storage exchange) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Exchange", id));
        assembly {
            exchange.slot := s
        }
    }

    /**
     * @dev Returns the exchange stored at the specified exchange id.
     */
    function exists(uint128 id) internal view returns (Data storage exchange) {
        exchange = load(id);

        if (id == 0 || exchange.id != id) {
            revert ExchangeNotFound(id);
        }
    }



}