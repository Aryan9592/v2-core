/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

library InstrumentRegistrar {


    /**
     * @dev Thrown when an instrument (market manager address) cannot be found
     */
    error InstrumentNotFound(address marketManagerAddress);


    struct Data {

        // instrument address -> isRegistered
        mapping(address => bool) registeredInstruments;

    }

    /**
     * @dev Returns the instrument registrar object
     */
    function load() private pure returns (Data storage instrumentRegistrar) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.InstrumentRegistrar"));
        assembly {
            instrumentRegistrar.slot := s
        }
    }

    function set(address instrumentAddress, bool isRegistered) internal {
        Data storage instrumentRegistrar = load();
        instrumentRegistrar.registeredInstruments[instrumentAddress] = isRegistered;
        // todo: emit event
    }

    function isInstrumentRegistered(address instrumentAddress) internal view returns (bool) {
        Data storage instrumentRegistrar = load();
        return instrumentRegistrar.registeredInstruments[instrumentAddress];
    }

    function exists(address instrumentAddress) internal view {
        Data storage instrumentRegistrar = load();
        if (!instrumentRegistrar.registeredInstruments[instrumentAddress]) {
            revert InstrumentNotFound(instrumentAddress);
        }
    }

}