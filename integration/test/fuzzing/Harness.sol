pragma solidity >=0.8.19;

import "./Hevm.sol";

import {AccountModule} from "../../src/proxies/Core.sol";

contract CoreRouter is AccountModule { } // router with a single module
contract CoreProxy is CoreRouter { } // not an actual proxy for now

contract Harness {
  CoreProxy coreProxy;

  constructor() {
    coreProxy = new CoreProxy();
  }

  function createAccount(
    address user, 
    uint128 requestedAccountId,
    bytes32 accountMode
  ) public {
    hevm.prank(user);
    try coreProxy.createAccount({
      requestedAccountId: requestedAccountId,
      accountOwner: user, 
      accountMode: accountMode
    }) {
      assert(true == true);
    } catch {
      assert(true == true);
    }
  }
}