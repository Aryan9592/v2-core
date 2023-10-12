pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/proxy/UUPSProxyWithOwner.sol";

import "@voltz-protocol/core/src/modules/AccountModule.sol";
import "@voltz-protocol/core/src/modules/AssociatedSystemsModule.sol";
import "@voltz-protocol/core/src/modules/CollateralConfigurationModule.sol";
import "@voltz-protocol/core/src/modules/CollateralModule.sol";
import "@voltz-protocol/core/src/modules/FeatureFlagModule.sol";
import "@voltz-protocol/core/src/modules/FeeConfigurationModule.sol";
import "@voltz-protocol/core/src/modules/liquidation/PreLiquidationModule.sol";
import "@voltz-protocol/core/src/modules/liquidation/RankedLiquidationModule.sol";
import "@voltz-protocol/core/src/modules/liquidation/DutchLiquidationModule.sol";
import "@voltz-protocol/core/src/modules/liquidation/BackstopLiquidationModule.sol";
import "@voltz-protocol/core/src/modules/OwnerUpgradeModule.sol";
import "@voltz-protocol/core/src/modules/MarketManagerModule.sol";
import "@voltz-protocol/core/src/modules/RiskConfigurationModule.sol";
import "@voltz-protocol/core/src/modules/AccessPassConfigurationModule.sol";

import "@voltz-protocol/core/src/modules/AccountTokenModule.sol";

contract CoreRouter is
  AccessPassConfigurationModule,
  AccountModule, 
  AssociatedSystemsModule,
  CollateralConfigurationModule,
  CollateralModule,
  FeatureFlagModule,
  FeeConfigurationModule,
  PreLiquidationModule,
  RankedLiquidationModule,
  DutchLiquidationModule,
  BackstopLiquidationModule,
  OwnerUpgradeModule,
  MarketManagerModule,
  RiskConfigurationModule
{ }

contract CoreProxy is
  UUPSProxyWithOwner,
  CoreRouter
{
  constructor(address firstImplementation, address initialOwner)
      UUPSProxyWithOwner(firstImplementation, initialOwner)
  {}
}

contract AccountNftRouter is AccountTokenModule {}

contract AccountNftProxy is 
  UUPSProxyWithOwner,
  AccountNftRouter
{
  constructor(address firstImplementation, address initialOwner)
      UUPSProxyWithOwner(firstImplementation, initialOwner)
  {}
}
