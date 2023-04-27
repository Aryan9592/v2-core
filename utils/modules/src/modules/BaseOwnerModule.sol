//SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "../interfaces/IBaseOwnerModule.sol";
import "@voltz-protocol/util-contracts/src/ownership/Ownable.sol";

/**
 * @title Module for giving a system owner based access control.
 * See IOwnerModule.
 */
contract BaseOwnerModule is Ownable, IBaseOwnerModule {
    // solhint-disable-next-line no-empty-blocks
    constructor() Ownable(address(0)) {
        // empty intentionally
    }

    // no impl intentionally
}
