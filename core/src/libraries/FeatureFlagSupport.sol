/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

library FeatureFlagSupport {

    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";
    bytes32 private constant _CREATE_ACCOUNT_FEATURE_FLAG = "createAccount";
    bytes32 private constant _NOTIFY_ACCOUNT_TRANSFER_FEATURE_FLAG = "notifyAccountTransfer";
    bytes32 private constant _COLLATERAL_POOL_ENABLED_FEATURE_FLAG = "collateralPoolEnabled";

    function ensureGlobalAccess() internal view {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
    }

    function ensureCreateAccountAccess() internal view {
        FeatureFlag.ensureAccessToFeature(_CREATE_ACCOUNT_FEATURE_FLAG);
    }

    function ensureNotifyAccountTransferAccess() internal view {
        FeatureFlag.ensureAccessToFeature(_NOTIFY_ACCOUNT_TRANSFER_FEATURE_FLAG);
    }

    function getCollateralPoolEnabledFeatureFlagId(uint128 collateralPoolId) internal pure returns(bytes32) {
        return keccak256(abi.encode(_COLLATERAL_POOL_ENABLED_FEATURE_FLAG, collateralPoolId));
    }

    function ensureEnabledCollateralPool(uint128 collateralPoolId) internal view {
        bytes32 flagId = getCollateralPoolEnabledFeatureFlagId(collateralPoolId);
        FeatureFlag.ensureAccessToFeature(flagId);
    }
}
