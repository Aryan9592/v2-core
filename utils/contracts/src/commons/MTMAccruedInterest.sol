//SPDX-License-Identifier: MIT
// todo: do we need reya license?

pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { mulUDxInt } from "../helpers/PrbMathHelper.sol";
import {Time} from "../helpers/Time.sol";

library MTMAccruedInterest {

    struct AccruedInterestTrackers {
        int256 accruedInterest;
        MTMObservation lastObservation;
    }

    struct MTMObservation {
        uint256 timestamp;
        UD60x18 rateIndex;
    }

    function getMTMAccruedInterestTrackers(
        AccruedInterestTrackers memory accruedInterestTrackers,
        MTMObservation memory newObservation,
        int256 baseBalance,
        int256 quoteBalance
    ) internal pure returns (AccruedInterestTrackers memory mtmAccruedInterestTrackers) {
        mtmAccruedInterestTrackers = accruedInterestTrackers;

        if (accruedInterestTrackers.lastObservation.timestamp < newObservation.timestamp) {
            UD60x18 annualizedTime = 
                Time.timeDeltaAnnualized(uint32(accruedInterestTrackers.lastObservation.timestamp), uint32(newObservation.timestamp));
            int256 accruedInterestDelta = 
                mulUDxInt(newObservation.rateIndex.sub(accruedInterestTrackers.lastObservation.rateIndex), baseBalance) +
                mulUDxInt(annualizedTime, quoteBalance);

            mtmAccruedInterestTrackers = AccruedInterestTrackers({
                accruedInterest: accruedInterestTrackers.accruedInterest + accruedInterestDelta,
                lastObservation: MTMObservation({
                    timestamp: newObservation.timestamp,
                    rateIndex: newObservation.rateIndex
                })
            });
        }
    }

}