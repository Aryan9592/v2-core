/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

import { ExecuteADLOrder } from "./ExecuteADLOrder.sol";

import { FilledBalances } from "../DataTypes.sol";
import { FeatureFlagSupport } from "../FeatureFlagSupport.sol";

import { Portfolio } from "../../storage/Portfolio.sol";
import { Market } from "../../storage/Market.sol";

import { BlendedADLLongId, BlendedADLShortId } from "@voltz-protocol/core/src/libraries/Constants.sol";
import { FeatureFlag } from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import { Timer } from "@voltz-protocol/util-contracts/src/helpers/Timer.sol";

/*
TODOs
    - add pre propagate order execution checks
    - revert if account has zero exposure to propagate
    - make sure accrued cashflows are also propagated
*/

/**
 * @title Library for propagating adl orders
 */
library PropagateADLOrder {
    using Timer for Timer.Data;
    using Portfolio for Portfolio.Data;
    using Market for Market.Data;

    /**
     * Thrown when ADL propagation is tried during blending period
     * @param marketId The id of the market in which the adl propagation was tried
     * @param isLong True if the adl propagation was a long order, False otherwise
     */
    error CannotPropagateADLDuringBlendingPeriod(uint128 marketId, bool isLong);

    /**
     * @dev Thrown when attempting to propagate an adl order in the wrong direction
     */
    error WrongADLPropagationDirection();

    function propagateADLOrder(uint128 accountId, uint128 marketId, uint32 maturityTimestamp, bool isLong) internal {
        // todo: this suffers from double propagations, we need to guard it
        // additionally, must make sure we don't propagate when blended order has 0 base

        Timer.Data storage adlPortfolioTimer = Timer.loadOrCreate(ExecuteADLOrder.adlOrderTimerId(isLong));
        if (adlPortfolioTimer.isActive()) {
            revert CannotPropagateADLDuringBlendingPeriod(marketId, isLong);
        }

        Market.Data storage market = Market.exists(marketId);
        address poolAddress = market.marketConfig.poolAddress;

        Portfolio.Data storage accountPortfolio = Portfolio.exists(accountId, marketId);

        FilledBalances memory filledBalances = accountPortfolio.getAccountFilledBalances(maturityTimestamp, poolAddress);

        // todo: why do we need to pass isLong if we can infer it from the sign of accountBaseFilled?
        if ((isLong && filledBalances.base > 0) || (!isLong && filledBalances.base < 0)) {
            revert WrongADLPropagationDirection();
        }

        Portfolio.Data storage adlPortfolio =
            isLong ? Portfolio.exists(BlendedADLLongId, market.id) : Portfolio.exists(BlendedADLShortId, market.id);

        // todo: calculate the share of base and quote to propagate
        int256 baseToPropagate = 0;
        int256 quoteToPropagate = 0;

        Portfolio.propagateMatchedOrder(
            accountPortfolio, adlPortfolio, baseToPropagate, quoteToPropagate, maturityTimestamp
        );

        // todo: check this once share to be propagated is compute above (must
        // pay attention to rounding errors)
        if (filledBalances.base == baseToPropagate && filledBalances.quote == quoteToPropagate) {
            // adl propagation is done, unpause maturity
            FeatureFlag.Data storage flag = FeatureFlag.load(
                FeatureFlagSupport.getMarketEnabledFeatureFlagId(accountPortfolio.marketId, maturityTimestamp)
            );
            flag.denyAll = false;
        }
    }
}
