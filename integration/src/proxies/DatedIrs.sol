pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/proxy/UUPSProxyWithOwner.sol";

import "@voltz-protocol/products-dated-irs/src/modules/MarketConfigurationModule.sol";
import "@voltz-protocol/products-dated-irs/src/modules/OwnerUpgradeModule.sol";
import "@voltz-protocol/products-dated-irs/src/modules/MarketManagerIRSModule.sol";
import "@voltz-protocol/products-dated-irs/src/modules/RateOracleModule.sol";
import "@voltz-protocol/core/src/modules/FeatureFlagModule.sol"; // todo: create one for product

contract DatedIrsRouter is
  MarketConfigurationModule, 
  OwnerUpgradeModule,
  MarketManagerIRSModule,
  RateOracleModule,
  FeatureFlagModule
{}

contract DatedIrsProxy is
  UUPSProxyWithOwner,
  DatedIrsRouter
{ 
  // solhint-disable-next-line no-empty-blocks
  constructor(address firstImplementation, address initialOwner)
      UUPSProxyWithOwner(firstImplementation, initialOwner)
  {}
}
