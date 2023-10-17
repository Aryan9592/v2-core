/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import { PositionBalances, RateOracleObservation } from "./DataTypes.sol";

import { mulUDxInt, mulSDxInt, divIntUD } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { convert as convert_ud } from "@prb/math/UD60x18.sol";
import { convert as convert_sd } from "@prb/math/SD59x18.sol";

library TraderPosition {
    using SafeCastU256 for uint256;

    function computeCashflow(
        int256 base,
        int256 quote,
        RateOracleObservation memory newObservation
    )
        internal
        pure
        returns (int256)
    {
        return mulUDxInt(newObservation.rateIndex, base)
            + divIntUD(mulSDxInt(convert_sd(newObservation.timestamp.toInt()), quote), convert_ud(Time.SECONDS_IN_YEAR));
    }

    function getAccruedInterest(
        PositionBalances memory balances,
        RateOracleObservation memory newObservation
    )
        internal
        pure
        returns (int256)
    {
        return computeCashflow(balances.base, balances.quote, newObservation) - balances.extraCashflow;
    }
}
