/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;


import {Portfolio} from "../../storage/Portfolio.sol";

/*
TODOs
    - add events
    - add natspec
    - add returns to execute liquidation order
*/

/**
 * @title Library for liquidation orders logic.
*/
library ExecuteLiquidationOrder {
    using Portfolio for Portfolio.Data;

    struct LiquidationOrderParams {
        uint128 liquidatableAccountId;
        uint128 liquidatorAccountId;
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseAmount;
        uint160 priceLimit;
    }


    function executeLiquidationOrder(
        LiquidationOrderParams memory params
    ) internal {

    }

}
