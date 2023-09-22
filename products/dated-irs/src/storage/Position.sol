/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {MarketRateOracle} from "../libraries/MarketRateOracle.sol";
import {MTMAccruedInterest} from  "@voltz-protocol/util-contracts/src/commons/MTMAccruedInterest.sol";

/**
 * @title Object for tracking a dated irs position
 */
library Position {
    struct Data {
        int256 baseBalance;
        int256 quoteBalance;
        MTMAccruedInterest.AccruedInterestTrackers accruedInterestTrackers;
    }

    function update(
        Data storage self, 
        int256 baseDelta, 
        int256 quoteDelta,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal {
        MTMAccruedInterest.MTMObservation memory newObservation = 
            MarketRateOracle.getNewMTMTimestampAndRateIndex(marketId, maturityTimestamp);
        self.accruedInterestTrackers = MTMAccruedInterest.getMTMAccruedInterestTrackers(
            self.accruedInterestTrackers,
            newObservation,
            self.baseBalance,
            self.quoteBalance
        );
        
        self.baseBalance += baseDelta;
        self.quoteBalance += quoteDelta;
    }
}
