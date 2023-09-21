/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Portfolio} from "../../storage/Portfolio.sol";
import {Market} from "../../storage/Market.sol";
import {IPool} from "../../interfaces/IPool.sol";
import {ExposureHelpers} from "../ExposureHelpers.sol";
import {mulUDxInt} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UNIT, UD60x18 } from "@prb/math/UD60x18.sol";

/*
TODOs
    - make sure long and short blended adl portfolio account ids cannot be created in the core
    - turn blended adl account ids into constants
    - return if base delta is zero
    - calculate quote delta with market price if no shortfall and with bankruptcy price if shortfall
    - kick off the adl timer
*/

/**
 * @title Library for adl order execution
*/
library ExecuteADLOrder {

    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    function computeQuoteDelta(
        int256 baseDelta,
        UD60x18 markPrice,
        uint128 marketId
    ) private returns (int256) {

        int256[] memory baseAmounts = new int256[](1);
        baseAmounts[0] = baseDelta;
        int256[] memory exposures = ExposureHelpers.baseToExposure(
            baseAmounts,
            marketId
        );

        return mulUDxInt(UNIT.add(markPrice), -exposures[0]);

    }

    function executeADLOrder(
        Portfolio.Data storage accountPortfolio,
        uint32 maturityTimestamp,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    ) internal {

        Market.Data storage market = Market.exists(accountPortfolio.marketId);
        address poolAddress = market.marketConfig.poolAddress;

        // extract filled base balance of the portfolio
        ExposureHelpers.PoolExposureState memory poolState = accountPortfolio.getPoolExposureState(
            maturityTimestamp,
            poolAddress
        );

        int256 baseDelta = poolState.baseBalance + poolState.baseBalancePool;

        // compute price (either bankruptcy or just market)
        // compute quote delta

        int256 quoteDelta = 0;

        Portfolio.Data storage adlPortfolio = baseDelta > 0 ? Portfolio.loadOrCreate(type(uint128).max - 1, market.id)
            : Portfolio.loadOrCreate(type(uint128).max - 2, market.id);

        accountPortfolio.updatePosition(maturityTimestamp, -baseDelta, -quoteDelta);
        adlPortfolio.updatePosition(maturityTimestamp, baseDelta, quoteDelta);

    }

}