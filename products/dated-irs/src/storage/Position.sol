/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";

/**
 * @title Object for tracking a dated irs position
 */
library Position {
    struct Data {
        int256 baseBalance;
        int256 quoteBalance;
        VammHelpers.AccruedInterestTrackers accruedInterestTrackers;
    }

    function update(
        Data storage self, 
        int256 baseDelta, 
        int256 quoteDelta,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal {
        self.accruedInterestTrackers = VammHelpers.getMTMAccruedInterestTrackers(
            self.accruedInterestTrackers,
            self.baseBalance,
            self.quoteBalance,
            marketId,
            maturityTimestamp
        );
        
        self.baseBalance += baseDelta;
        self.quoteBalance += quoteDelta;
    }
}
