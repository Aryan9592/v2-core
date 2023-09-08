/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {FeatureFlag} from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

library FeatureFlagSupport {

    bytes32 private constant _MARKET_ENABLED_FEATURE_FLAG = "marketEnabled";

    function getMarketEnabledFeatureFlagId(uint128 marketId) internal pure returns(bytes32) {
        return keccak256(abi.encode(_MARKET_ENABLED_FEATURE_FLAG, marketId));
    }

    function ensureEnabledMarket(uint128 marketId) internal view {
        bytes32 flagId = getMarketEnabledFeatureFlagId(marketId);
        FeatureFlag.ensureAccessToFeature(flagId);
    }
}
