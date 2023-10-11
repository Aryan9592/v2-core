/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import { UD60x18, mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

struct RateOracleObservation {
    uint256 timestamp;
    UD60x18 rateIndex;
}

struct PositionBalances {
    int256 base;
    int256 quote;
    int256 extraCashflow;
}

struct FilledBalances {
    int256 base;
    int256 quote;
    int256 accruedInterest;
}

struct UnfilledBalances {
    uint256 baseLong;
    uint256 baseShort;
    uint256 quoteLong;
    uint256 quoteShort;
}

struct MakerOrderParams {
    uint128 accountId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int24 tickLower;
    int24 tickUpper;
    int256 baseDelta;
}