/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { Market } from "../storage/Market.sol";
import { IRateOracle } from "../interfaces/IRateOracle.sol";

import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { UD60x18, unwrap } from "@prb/math/UD60x18.sol";

import {IERC165} from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

library MarketRateOracle {
    using { unwrap } for UD60x18;
    /**
     * @dev Thrown if the index-at-maturity is requested before maturity.
     */

    error MaturityNotReached();


    /**
     * @dev Thrown if more than maturityIndexCachingWindowInSeconds has elapsed since the maturity timestamp
     */

    error MaturityIndexCachingWindowElapsed();


    /**
     * @dev Thrown if the maturity index caching window is ongoing in context of maturity index backfill
     */
    error MaturityIndexCachingWindowOngoing();


    /**
     * @notice Emitted when new maturity rate is cached
     * @param marketId The id of the market.
     * @param oracleAddress The address of the oracle.
     * @param timestamp The timestamp of the rate.
     * @param rate The value of the rate.
     * @param blockTimestamp The current block timestamp.
     */
    event RateOracleCacheUpdated(
        uint128 indexed marketId, address oracleAddress, uint32 timestamp, uint256 rate, uint256 blockTimestamp
    );

    function backfillRateIndexAtMaturityCache(
        Market.Data storage self, 
        uint32 maturityTimestamp, 
        UD60x18 rateIndexAtMaturity
    ) internal {
        if (Time.blockTimestampTruncated() < maturityTimestamp) {
            revert MaturityNotReached();
        }

        if (Time.blockTimestampTruncated() < maturityTimestamp + self.rateOracleConfig.maturityIndexCachingWindowInSeconds) {
            revert MaturityIndexCachingWindowOngoing();
        }

        self.rateIndexAtMaturity[maturityTimestamp] = rateIndexAtMaturity;

        emit RateOracleCacheUpdated(
            self.id,
            self.rateOracleConfig.oracleAddress,
            maturityTimestamp,
            self.rateIndexAtMaturity[maturityTimestamp].unwrap(),
            block.timestamp
        );
    }

    function updateRateIndexAtMaturityCache(Market.Data storage self, uint32 maturityTimestamp) internal {

        if (self.rateIndexAtMaturity[maturityTimestamp].unwrap() == 0) {

            if (Time.blockTimestampTruncated() < maturityTimestamp) {
                revert MaturityNotReached();
            }

            if (Time.blockTimestampTruncated() > maturityTimestamp + self.rateOracleConfig.maturityIndexCachingWindowInSeconds) {
                revert MaturityIndexCachingWindowElapsed();
            }

            self.rateIndexAtMaturity[maturityTimestamp] = IRateOracle(self.rateOracleConfig.oracleAddress).getCurrentIndex();

            emit RateOracleCacheUpdated(
                self.id,
                self.rateOracleConfig.oracleAddress,
                maturityTimestamp,
                self.rateIndexAtMaturity[maturityTimestamp].unwrap(),
                block.timestamp
            );
        }

    }

    function getRateIndexCurrent(Market.Data storage self) internal view returns (UD60x18 rateIndexCurrent) {
        /*
            Note, need thoughts here for protocols where current index does not correspond to the current timestamp (block.timestamp)
            ref. Lido and Rocket
        */
        return IRateOracle(self.rateOracleConfig.oracleAddress).getCurrentIndex();
    }

    function getRateIndexMaturity(
        Market.Data storage self, 
        uint32 maturityTimestamp
    ) internal view returns (UD60x18 rateIndexMaturity) {
        /*
            Note, for some period of time (until cache is captured) post maturity, the rate index cached for the maturity
            will be zero
        */
        if (Time.blockTimestampTruncated() <= maturityTimestamp) {
            revert MaturityNotReached();
        }

        return self.rateIndexAtMaturity[maturityTimestamp];
    }

    function updateOracleStateIfNeeded(Market.Data storage self) internal {
        if (
            IRateOracle(self.rateOracleConfig.oracleAddress).hasState() && 
            IRateOracle(self.rateOracleConfig.oracleAddress).earliestStateUpdate() <= block.timestamp
        ) {
            IRateOracle(self.rateOracleConfig.oracleAddress).updateState();
        }
    }
}
