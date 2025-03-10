// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity >=0.8.13;

import { FeatureFlagModule as BaseFeatureFlagModule } from
    "@voltz-protocol/util-modules/src/modules/FeatureFlagModule.sol";

/**
 * @title Module that allows disabling certain system features
 * @notice Users will not be able to interact with certain functions associated to disabled features
 */
// solhint-disable-next-line no-empty-blocks
contract FeatureFlagModule is BaseFeatureFlagModule { }
