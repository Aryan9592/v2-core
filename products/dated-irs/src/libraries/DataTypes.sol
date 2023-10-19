/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import { Account } from "@voltz-protocol/core/src/storage/Account.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

enum OrderDirection {
    Short,
    Zero,
    Long
}

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
    Account.PnLComponents pnl;
}

struct UnfilledBalances {
    uint256 baseLong;
    uint256 baseShort;
    uint256 quoteLong;
    uint256 quoteShort;
    UD60x18 averagePriceLong;
    UD60x18 averagePriceShort;
}

struct MakerOrderParams {
    uint128 accountId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int24 tickLower;
    int24 tickUpper;
    int256 baseDelta;
}

struct TakerOrderParams {
    uint128 accountId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int256 baseDelta;
    uint160 priceLimit;
}

struct LiquidationOrderParams {
    uint128 liquidatableAccountId;
    uint128 liquidatorAccountId;
    uint128 marketId;
    uint32 maturityTimestamp;
    int256 baseAmountToBeLiquidated;
    uint256 priceLimit;
}
