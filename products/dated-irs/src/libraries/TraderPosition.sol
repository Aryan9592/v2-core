/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import { UD60x18, mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import { PositionBalances, MTMObservation } from "./DataTypes.sol";

library TraderPosition {
    error MarkingToMarketInThePast(MTMObservation currentObservation, MTMObservation newObservation);

    function getUpdatedBalances(
        PositionBalances memory balances,
        int256 baseDelta,
        int256 quoteDelta,
        MTMObservation memory newObservation
    ) internal pure returns (PositionBalances memory /* updatedBalances */) {
        if (balances.lastObservation.timestamp > newObservation.timestamp) {
            revert MarkingToMarketInThePast(balances.lastObservation, newObservation);
        }

        bool shouldMarkToMarket = balances.lastObservation.timestamp < newObservation.timestamp;
        int256 accruedInterestDelta = 0;

        if (shouldMarkToMarket) {
            UD60x18 annualizedTime = 
                Time.timeDeltaAnnualized(uint32(balances.lastObservation.timestamp), uint32(newObservation.timestamp));
                
            accruedInterestDelta = 
                mulUDxInt(newObservation.rateIndex.sub(balances.lastObservation.rateIndex), balances.base) +
                mulUDxInt(annualizedTime, balances.quote);
        }

        return PositionBalances({
            base: balances.base + baseDelta,
            quote: balances.quote + quoteDelta,
            accruedInterest: balances.accruedInterest + accruedInterestDelta,
            lastObservation: (shouldMarkToMarket) ? newObservation : balances.lastObservation
        });
    }

    function updateBalances(
        PositionBalances storage balances,
        int256 baseDelta,
        int256 quoteDelta,
        MTMObservation memory newObservation
    ) internal {
        PositionBalances memory updatedBalances = getUpdatedBalances(
            balances,
            baseDelta,
            quoteDelta,
            newObservation
        );

        balances.base = updatedBalances.base;
        balances.quote = updatedBalances.quote;
        balances.accruedInterest = updatedBalances.accruedInterest;
        balances.lastObservation = updatedBalances.lastObservation;
    }
}