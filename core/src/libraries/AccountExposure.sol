/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";
import "../storage/CollateralConfiguration.sol";
import "../storage/Market.sol";
import "../storage/ProtocolRiskConfiguration.sol";

import {mulUDxUint, UD60x18} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Object for tracking account margin requirements.
 */
library AccountExposure {
    using Account for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Market for Market.Data;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;

    struct MarginRequirements {
        bool isIMSatisfied;
        bool isLMSatisfied;
        uint256 initialMarginRequirement;
        uint256 liquidationMarginRequirement;
        uint256 highestUnrealizedLoss;
    }

    /**
     * @dev Note, for dated instruments we don't need to keep track of the maturity
     because the risk parameter is shared across maturities for a given marketId
     */
    struct MarketExposure {
        int256 annualizedNotional;
        // note, in context of dated irs with the current accounting logic it also includes accruedInterest
        uint256 unrealizedLoss;
    }

    struct MakerMarketExposure {
        MarketExposure lower;
        MarketExposure upper;
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account and highest unrealized loss
     * for a given collateral type along with the flags for im or lm satisfied
     * @dev If the account is single-token, the amounts are in collateral type. 
     *      Otherwise, if the account is multi-token, the amounts are in USD.
     */
    // todo: do we want for this function to return values in USD or leave for collateral type?
    function getMarginRequirementsAndHighestUnrealizedLoss(Account.Data storage self, address collateralType)
        internal
        view
        returns (MarginRequirements memory mr)
    {
        uint256 collateralBalance = 0;
    
        if (self.isMultiToken) {

            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);
                CollateralConfiguration.Data storage collateral = CollateralConfiguration.load(quoteToken);

                (uint256 liquidationMarginRequirementInCollateral, uint256 highestUnrealizedLossInCollateral) = 
                    getRequirementsAndHighestUnrealizedLossByCollateralType(self, quoteToken);

                uint256 liquidationMarginRequirementInUSD = collateral.getCollateralInUSD(liquidationMarginRequirementInCollateral);
                uint256 highestUnrealizedLossInUSD = collateral.getCollateralInUSD(highestUnrealizedLossInCollateral);

                mr.liquidationMarginRequirement += liquidationMarginRequirementInUSD;
                mr.highestUnrealizedLoss += highestUnrealizedLossInUSD;
            }

            collateralBalance = self.getWeightedCollateralBalanceInUSD();
        }
        else {
            // we don't need to convert the amounts to USD because single-token accounts have requirements in quote token

            (mr.liquidationMarginRequirement, mr.highestUnrealizedLoss) = 
                    getRequirementsAndHighestUnrealizedLossByCollateralType(self, collateralType);

            collateralBalance = self.getCollateralBalance(collateralType);
        }

        UD60x18 imMultiplier = getIMMultiplier();
        mr.initialMarginRequirement = computeInitialMarginRequirement(mr.liquidationMarginRequirement, imMultiplier);

        mr.isIMSatisfied = collateralBalance >= mr.initialMarginRequirement + mr.highestUnrealizedLoss;
        mr.isLMSatisfied = collateralBalance >= mr.liquidationMarginRequirement + mr.highestUnrealizedLoss;
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account and highest unrealized loss
     * for a given collateral type along with the flags for im satisfied or lm satisfied
     * @dev If the account is single-token, the amounts are in collateral type. 
     *      Otherwise, if the account is multi-token, the amounts are in USD.
     */
    function getRequirementsAndHighestUnrealizedLossByCollateralType(Account.Data storage self, address collateralType)
        internal
        view
        returns (uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss)
    {
        SetUtil.UintSet storage markets = self.activeMarketsPerQuoteToken[collateralType];

        for (uint256 i = 1; i <= markets.length(); i++) {
            uint128 marketId = markets.valueAt(i).to128();

            // Get the risk parameter of the market
            UD60x18 riskParameter = getRiskParameter(marketId);

            // Get taker and maker exposure to the market
            MakerMarketExposure[] memory makerExposures = 
                Market.exists(marketId).getAccountTakerAndMakerExposures(self.id);

            // Aggregate LMR and unrealized loss for all exposures
            for (uint256 j = 0; j < makerExposures.length; j++) {
                MarketExposure memory exposureLower = makerExposures[j].lower;
                MarketExposure memory exposureUpper = makerExposures[j].upper;

                uint256 lowerLMR = 
                    computeLiquidationMarginRequirement(exposureLower.annualizedNotional, riskParameter);

               if (equalExposures(exposureLower, exposureUpper)) {
                    liquidationMarginRequirement += lowerLMR;
                    highestUnrealizedLoss += exposureLower.unrealizedLoss;
               }
               else {
                    uint256 upperLMR = 
                        computeLiquidationMarginRequirement(exposureUpper.annualizedNotional, riskParameter);

                    if (
                        lowerLMR + exposureLower.unrealizedLoss >
                        upperLMR + exposureUpper.unrealizedLoss
                    ) {
                        liquidationMarginRequirement += lowerLMR;
                        highestUnrealizedLoss += exposureLower.unrealizedLoss;
                    } else {
                        liquidationMarginRequirement += upperLMR;
                        highestUnrealizedLoss += exposureUpper.unrealizedLoss;
                    }
               }
            }
        }
    }

    function getRiskParameter(uint128 marketId) internal view returns (UD60x18 riskParameter) {
        return Market.exists(marketId).riskConfig.riskParameter;
    }

    /**
     * @dev Note, im multiplier is assumed to be the same across all markets and maturities
     */
    function getIMMultiplier() internal view returns (UD60x18 imMultiplier) {
        return ProtocolRiskConfiguration.load().imMultiplier;
    }

    /**
     * @dev Returns the liquidation margin requirement given the annualized exposure and the risk parameter
     */
    function computeLiquidationMarginRequirement(int256 annualizedNotional, UD60x18 riskParameter)
    internal
    pure
    returns (uint256 liquidationMarginRequirement)
    {

        uint256 absAnnualizedNotional = annualizedNotional < 0 ? uint256(-annualizedNotional) : uint256(annualizedNotional);
        liquidationMarginRequirement = mulUDxUint(riskParameter, absAnnualizedNotional);
        return liquidationMarginRequirement;
    }

    /**
     * @dev Returns the initial margin requirement given the liquidation margin requirement and the im multiplier
     */
    function computeInitialMarginRequirement(uint256 liquidationMarginRequirement, UD60x18 imMultiplier)
    internal
    pure
    returns (uint256 initialMarginRequirement)
    {
        initialMarginRequirement = mulUDxUint(imMultiplier, liquidationMarginRequirement);
    }

    function equalExposures(MarketExposure memory a, MarketExposure memory b) internal pure returns (bool) {
        if (
            a.annualizedNotional == b.annualizedNotional && 
            a.unrealizedLoss == b.unrealizedLoss
        ) {
            return true;
        }

        return false;
    }
}
