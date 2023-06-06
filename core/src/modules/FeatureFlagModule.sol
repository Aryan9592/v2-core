// https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
pragma solidity >=0.8.19;

import {FeatureFlagModule as BaseFeatureFlagModule} from
    "@voltz-protocol/util-modules/src/modules/FeatureFlagModule.sol";

/**
 * @title Module that allows disabling certain system features.
 *
 * Users will not be able to interact with certain functions associated to disabled features.
 */
// solhint-disable-next-line no-empty-blocks
contract FeatureFlagModule is BaseFeatureFlagModule {}
