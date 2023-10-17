// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { UUPSProxyWithOwner } from "@voltz-protocol/util-contracts/src/proxy/UUPSProxyWithOwner.sol";

/**
 * @title Voltz V2 VAMM Proxy Contract
 */
contract VammProxy is UUPSProxyWithOwner {
    // solhint-disable-next-line no-empty-blocks
    constructor(
        address firstImplementation,
        address initialOwner
    )
        UUPSProxyWithOwner(firstImplementation, initialOwner)
    { }
}
