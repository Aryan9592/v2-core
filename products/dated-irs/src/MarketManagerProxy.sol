/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/proxy/UUPSProxyWithOwner.sol";

/**
 * Voltz V2 Market Manager Proxy Contract
 */
contract MarketManagerProxy is UUPSProxyWithOwner {
    // solhint-disable-next-line no-empty-blocks
    constructor(address firstImplementation, address initialOwner) UUPSProxyWithOwner(firstImplementation, initialOwner) { }
}
