// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/products-dated-irs/src/interfaces/IMarketManagerIRSModule.sol";
import { IVammModule } from "@voltz-protocol/v2-vamm/src/interfaces/IVammModule.sol";
import "../storage/Config.sol";
import "./AccessControl.sol";

/**
 * @title Performs swaps and settements on top of the v2 dated irs instrument
 */
library V2DatedIRS {
    function swap(uint128 accountId, uint128 marketId, uint32 maturityTimestamp, int256 baseAmount, uint160 priceLimit)
        internal
        returns (
            int256 executedBaseAmount,
            int256 executedQuoteAmount,
            uint256 fee,
            AccountExposure.MarginRequirements memory mr,
            int24 currentTick
        )
    {
        AccessControl.onlyOwner(accountId);

        IMarketManagerIRSModule.TakerOrderParams memory params  = IMarketManagerIRSModule.TakerOrderParams({
            accountId: accountId,
            marketId: marketId,
            maturityTimestamp: maturityTimestamp,
            baseAmount: baseAmount,
            priceLimit: priceLimit
        }); 
    
        (executedBaseAmount, executedQuoteAmount, fee, mr) =
            IMarketManagerIRSModule(Config.load().VOLTZ_V2_DATED_IRS_PROXY)
                .initiateTakerOrder(params);

        // Get current tick
        currentTick = IVammModule(Config.load().VOLTZ_V2_DATED_IRS_VAMM_PROXY).getVammTick(marketId, maturityTimestamp);
    }

    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) internal {
        AccessControl.onlyOwner(accountId);
    
        IMarketManagerIRSModule(Config.load().VOLTZ_V2_DATED_IRS_PROXY).settle(accountId, marketId, maturityTimestamp);
    }
}
