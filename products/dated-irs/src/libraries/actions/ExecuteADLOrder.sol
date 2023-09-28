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
import { UD60x18 } from "@prb/math/UD60x18.sol";
import {mulDiv} from "@prb/math/UD60x18.sol";
import {Timer} from "@voltz-protocol/util-contracts/src/helpers/Timer.sol";

/*
TODOs
    - consider removing spread and slippage from upnl calc -> can really mess up some of the calcs below
    -- margin requirements are support to take care of that
    - make sure long and short blended adl portfolio account ids cannot be created in the core
    - turn blended adl account ids into constants
    - return if base delta is zero
    - calculate quote delta with market price if no shortfall and with bankruptcy price if shortfall
    - kick off the adl timer
    - make sure bankruptcy calc is reverted if cover is sufficient (shouldn't happen in practice)
*/

/**
 * @title Library for adl order execution
*/
library ExecuteADLOrder {
    using Timer for Timer.Data;
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * @notice Thrown when an ADL order comes in during propagation of a
     * previous blended ADL order
     * @param marketId The id of the market in which the account was tried to be adl'ed
     * @param accountId The id of the account that was tried to be adl'ed
     * @param baseDelta The base delta that was tried to be adl'ed
     */
    error CannotBlendADLDuringPropagation(uint128 marketId, uint128 accountId, int256 baseDelta);

    function computeQuoteDelta(
        int256 baseDelta,
        UD60x18 markPrice,
        uint128 marketId
    ) private view returns (int256) {

        int256 exposure = ExposureHelpers.baseToExposure(
            baseDelta,
            marketId
        );

        return mulUDxInt(markPrice, exposure);

    }

    function computeBankruptcyPrice(
        int256 baseDelta,
        uint256 positionUnrealizedLoss,
        uint256 totalUnrealizedLoss,
        int256 realBalanceAndIF
    ) private view returns (UD60x18 bankruptcyPrice) {

        // todo: finish implementation once pnl calc is fixed

        //  uint256 cover = mulDiv(positionUnrealizedLoss, realBalanceAndIF, totalUnrealizedLoss);
        // todo: compute unrealized loss here (make sure the calc in exposure helpers is correct)

        return bankruptcyPrice;
    }

    struct ExecuteADLOrderVars {
        address poolAddress;
        int256 baseDelta;
        int256 quoteDelta;
        UD60x18 markPrice;
        bool isLong;
    }

    function executeADLOrder(
        Portfolio.Data storage accountPortfolio,
        uint32 maturityTimestamp,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    ) internal {
        ExecuteADLOrderVars memory vars;

        Market.Data storage market = Market.exists(accountPortfolio.marketId);
        vars.poolAddress = market.marketConfig.poolAddress;

        ExposureHelpers.PoolExposureState memory poolState = accountPortfolio.getPoolExposureState(
            maturityTimestamp,
            vars.poolAddress
        );

        vars.baseDelta = poolState.baseBalance + poolState.baseBalancePool;

        if (totalUnrealizedLossQuote > 0) {
            // todo: (AB) link this to uPnL functions
            uint256 positionUnrealizedLoss = 0;
            
            vars.markPrice = computeBankruptcyPrice(
                vars.baseDelta,
                positionUnrealizedLoss,
                totalUnrealizedLossQuote,
                realBalanceAndIF
            );
        } else {
            vars.markPrice = IPool(vars.poolAddress).getAdjustedDatedIRSTwap(
                accountPortfolio.marketId,
                maturityTimestamp,
                0,
                market.marketConfig.twapLookbackWindow
            );
        }

        vars.quoteDelta = computeQuoteDelta(vars.baseDelta, vars.markPrice, accountPortfolio.marketId);

        vars.isLong = vars.baseDelta > 0;

        Portfolio.Data storage adlPortfolio = vars.isLong ? Portfolio.loadOrCreate(type(uint128).max - 1, market.id)
            : Portfolio.loadOrCreate(type(uint128).max - 2, market.id);
        
        Timer.Data storage adlPortfolioTimer = Timer.loadOrCreate(adlOrderTimerId(vars.isLong));
        /// todo: need to think how propagation can achieve exactly 0 in base & quote balances,
        /// given numerical errors
        if (adlPortfolio.positions[maturityTimestamp].baseBalance == 0) {
            adlPortfolioTimer.start(
                market.adlBlendingDurationInSeconds
            );
        } else {
            if (!adlPortfolioTimer.isActive()) {
                revert CannotBlendADLDuringPropagation(accountPortfolio.marketId, accountPortfolio.accountId, vars.baseDelta);
            }
        }

        accountPortfolio.updatePosition(maturityTimestamp, -vars.baseDelta, -vars.quoteDelta);
        adlPortfolio.updatePosition(maturityTimestamp, vars.baseDelta, vars.quoteDelta);

    }

    function adlOrderTimerId(bool isLong) internal pure returns (bytes32) {
        return (isLong) ? bytes32("LongBlendedAdlOrderTimer") : bytes32("ShortBlendedAdlOrderTimer");
    }
}