/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IInstrumentRegistrarModule} from "../interfaces/IInstrumentRegistrarModule.sol";
import {InstrumentRegistrar} from "../storage/InstrumentRegistrar.sol";
import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";


contract InstrumentRegistrarModule is IInstrumentRegistrarModule {

    /**
     * @inheritdoc IInstrumentRegistrarModule
     */
    function setInstrumentRegistrationFlag(address instrumentAddress, bool isRegistered) external {
        OwnableStorage.onlyOwner();
        InstrumentRegistrar.set(instrumentAddress, isRegistered);
    }

    /**
     * @inheritdoc IInstrumentRegistrarModule
     */
    function isInstrumentRegistered(address instrumentAddress) external view returns (bool) {
        return InstrumentRegistrar.isInstrumentRegistered(instrumentAddress);
    }


}