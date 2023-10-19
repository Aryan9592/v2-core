/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { Portfolio } from "../../storage/Portfolio.sol";
import { Market } from "../../storage/Market.sol";
import { FilledBalances } from "../DataTypes.sol";
import { ExposureHelpers } from "../ExposureHelpers.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";
import { mulDiv } from "@prb/math/SD59x18.sol";
import { Timer } from "@voltz-protocol/util-contracts/src/helpers/Timer.sol";

import { FeatureFlag } from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import { FeatureFlagSupport } from "../FeatureFlagSupport.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

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
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;

    /**
     * @notice Thrown when an ADL order comes in during propagation of a
     * previous blended ADL order
     * @param marketId The id of the market in which the account was tried to be adl'ed
     * @param accountId The id of the account that was tried to be adl'ed
     * @param baseDelta The base delta that was tried to be adl'ed
     */
    error CannotBlendADLDuringPropagation(uint128 marketId, uint128 accountId, int256 baseDelta);

    error PositiveUPnLDuringBakruptcyADL(uint128 marketId, uint32 maturityTimestamp, uint128 accountId, uint256 upnl);

    function computeBankruptcyPrice(
        uint32 maturityTimestamp,
        int256 baseBalance,
        int256 quoteBalance,
        uint256 positionUnrealizedLoss,
        uint256 totalUnrealizedLoss,
        int256 realBalanceAndIF,
        UD60x18 exposureFactor
    )
        private
        view
        returns (UD60x18 bankruptcyPrice)
    {
        uint256 absRealBalanceAndIF = (realBalanceAndIF > 0) ? realBalanceAndIF.toUint() : (-realBalanceAndIF).toUint();
        uint256 absCover = mulDiv(absRealBalanceAndIF, positionUnrealizedLoss, totalUnrealizedLoss);
        int256 cover = (realBalanceAndIF > 0) ? absCover.toInt() : -absCover.toInt();

        bankruptcyPrice = ExposureHelpers.computeUnwindPriceForGivenUPnL({
            maturityTimestamp: maturityTimestamp,
            baseBalance: baseBalance,
            quoteBalance: quoteBalance,
            uPnL: cover,
            exposureFactor: exposureFactor
        }).intoUD60x18(); // todo: need to check this with @0xZenus @arturbeg, we do not want to revert adl
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
    )
        internal
    {
        // pause maturity until adl propagation is done
        FeatureFlag.Data storage flag = FeatureFlag.load(
            FeatureFlagSupport.getMarketEnabledFeatureFlagId(accountPortfolio.marketId, maturityTimestamp)
        );
        flag.denyAll = true;

        ExecuteADLOrderVars memory vars;

        Market.Data storage market = Market.exists(accountPortfolio.marketId);
        vars.poolAddress = market.marketConfig.poolAddress;
        UD60x18 exposureFactor = market.exposureFactor();

        FilledBalances memory filledBalances =
            accountPortfolio.getAccountFilledBalances(maturityTimestamp, vars.poolAddress);

        if (totalUnrealizedLossQuote > 0) {
            if (filledBalances.pnl.unrealizedPnL > 0) {
                revert PositiveUPnLDuringBakruptcyADL(
                    accountPortfolio.marketId,
                    maturityTimestamp,
                    accountPortfolio.accountId,
                    filledBalances.pnl.unrealizedPnL.toUint()
                );
            }

            uint256 positionUnrealizedLoss = (-filledBalances.pnl.unrealizedPnL).toUint();
            vars.markPrice = computeBankruptcyPrice({
                maturityTimestamp: maturityTimestamp,
                baseBalance: filledBalances.base,
                quoteBalance: filledBalances.quote,
                positionUnrealizedLoss: positionUnrealizedLoss,
                totalUnrealizedLoss: totalUnrealizedLossQuote,
                realBalanceAndIF: realBalanceAndIF,
                exposureFactor: exposureFactor
            });
        } else {
            vars.markPrice = ExposureHelpers.computeTwap(market.id, maturityTimestamp, vars.poolAddress, 0, exposureFactor);
        }

        vars.baseDelta = filledBalances.base;
        vars.quoteDelta = ExposureHelpers.computeQuoteDelta(vars.baseDelta, vars.markPrice, exposureFactor);

        vars.isLong = vars.baseDelta > 0;

        Portfolio.Data storage adlPortfolio = vars.isLong
            ? Portfolio.loadOrCreate(type(uint128).max - 1, market.id)
            : Portfolio.loadOrCreate(type(uint128).max - 2, market.id);

        Timer.Data storage adlPortfolioTimer = Timer.loadOrCreate(adlOrderTimerId(vars.isLong));
        /// todo: need to think how propagation can achieve exactly 0 in base & quote balances,
        /// given numerical errors
        if (adlPortfolio.positions[maturityTimestamp].base == 0) {
            adlPortfolioTimer.start(market.adlBlendingDurationInSeconds);
        } else {
            if (!adlPortfolioTimer.isActive()) {
                revert CannotBlendADLDuringPropagation(
                    accountPortfolio.marketId, accountPortfolio.accountId, vars.baseDelta
                );
            }
        }

        Portfolio.propagateMatchedOrder(
            adlPortfolio, accountPortfolio, vars.baseDelta, vars.quoteDelta, maturityTimestamp
        );
    }

    function adlOrderTimerId(bool isLong) internal pure returns (bytes32) {
        return (isLong) ? bytes32("LongBlendedAdlOrderTimer") : bytes32("ShortBlendedAdlOrderTimer");
    }
}
