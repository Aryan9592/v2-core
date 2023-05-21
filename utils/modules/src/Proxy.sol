pragma solidity >=0.8.19;

import {UUPSProxyWithOwner} from "@voltz-protocol/util-contracts/src/proxy/UUPSProxyWithOwner.sol";

contract Proxy is UUPSProxyWithOwner {
    // solhint-disable-next-line no-empty-blocks
    constructor(address firstImplementation, address initialOwner)
        UUPSProxyWithOwner(firstImplementation, initialOwner)
    {}
}
