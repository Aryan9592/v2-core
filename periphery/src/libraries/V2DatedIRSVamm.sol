// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/core/src/storage/Account.sol";
import { IPoolModule } from "@voltz-protocol/v2-vamm/src/interfaces/IPoolModule.sol";
import "../storage/Config.sol";
import "./AccessControl.sol";

/**
 * @title Performs mints and burns on top of the v2 dated irs exchange
 */
library V2DatedIRSVamm {
    function initiateDatedMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta
    )
        internal returns (uint256 fee, Account.MarginRequirement memory mr)
     {
        AccessControl.onlyOwner(accountId);

        (fee, mr) = IPoolModule(Config.load().VOLTZ_V2_DATED_IRS_VAMM_PROXY)
            .initiateDatedMakerOrder(accountId, marketId, maturityTimestamp, tickLower, tickUpper, liquidityDelta);
    }
}