/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";

import {UD60x18} from "@prb/math/UD60x18.sol";

/**
 * @title Object for tracking a dated irs position
 */
library Position {
    struct Data {
        int256 baseBalance;
        int256 quoteBalance;
        int256 accruedInterest;
		uint256 lastMTMTimestamp;
		UD60x18 lastMTMRateIndex;
    }

    function update(
        Data storage self, 
        int256 baseDelta, 
        int256 quoteDelta,
        uint256 newMTMTimestamp,
        UD60x18 newMTMRateIndex
    ) internal {
        if (self.lastMTMTimestamp < newMTMTimestamp) {
            self.accruedInterest += 
                ExposureHelpers.getMTMAccruedInterest(
                    self.baseBalance,
                    self.quoteBalance,
                    self.lastMTMTimestamp,
                    newMTMTimestamp,
                    self.lastMTMRateIndex,
                    newMTMRateIndex
                );
            self.lastMTMTimestamp = newMTMTimestamp;
            self.lastMTMRateIndex = newMTMRateIndex;
        }
        
        self.baseBalance += baseDelta;
        self.quoteBalance += quoteDelta;
    }
}
