/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./ExchangeStore.sol";
import "./Account.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";
import {ExchangePassConfiguration} from "./ExchangePassConfiguration.sol";
import {INFTPass} from "../interfaces/external/INFTPass.sol";

library Exchange {

    /**
     * @dev Thrown when an exchange cannot be found.
     */
    error ExchangeNotFound(uint128 exchangeId);

    /**
     * @dev Thrown when an exchange wants to register or perform an action but doesn't own the exchange pass
     */
    error OnlyExchangePassOwner();

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

        mapping(address => UD60x18) feeRebatesPerInstrument;

    }

    function create(uint128 exchangeFeeCollectorAccountId) internal returns (Data storage exchange) {
        uint128 id = ExchangeStore.advanceExchangeId();
        exchange = load(id);
        exchange.id = id;
        exchange.exchangeFeeCollectorAccountId = exchangeFeeCollectorAccountId;

        // todo: make sure account exists

        // todo: add event

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

    function setFeeRebate(
        Data storage self,
        address instrumentAddress,
        UD60x18 rebateParameter
    ) internal {

        // todo: validation to make sure rebateParameter is between zero and 1
        self.feeRebatesPerInstrument[instrumentAddress] = rebateParameter;
        // todo: add event
    }

    function passCheck(
        Data storage self
    ) internal view {

        address accountOwner = Account.exists(self.exchangeFeeCollectorAccountId).rbac.owner;

        address exchangePassNFTAddress = ExchangePassConfiguration.exists().exchangePassNFTAddress;

        uint256 ownerExchangePassBalance = INFTPass(exchangePassNFTAddress).balanceOf(accountOwner);
        if (ownerExchangePassBalance == 0) {
            revert OnlyExchangePassOwner();
        }

    }



}