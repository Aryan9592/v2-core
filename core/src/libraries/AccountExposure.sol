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

    error UnsupportedAccountExposure(bytes32 accountMode);

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account and highest unrealized loss
     * for a given collateral type along with the flags for im or lm satisfied
     * @dev If the collateral is zero address, the amounts are in USD terms. 
     * Otherwise, the amounts are in collateral type. 
     */
    function getMarginRequirementsAndHighestUnrealizedLoss(Account.Data storage self, address collateralType)
        internal
        view
        returns (Account.MarginRequirement memory)
    {
        // Fetch the IM multiplier
        UD60x18 imMultiplier = self.getCollateralPool().riskConfig.imMultiplier;

        if (self.accountMode == Account.SINGLE_TOKEN_MODE) {
            // get the margin requirements and highest unrealized loss for this particular collateral type
            (uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss) = 
                    getRequirementsAndHighestUnrealizedLossByCollateralType(self, collateralType);

            // get the collateral balance
            uint256 collateralBalance = self.getCollateralBalance(collateralType);
            
            // compute the flag for LM satisfied
            bool isLMSatisfied = collateralBalance >= liquidationMarginRequirement + highestUnrealizedLoss;

            // compute the initial margin requirement
            uint256 initialMarginRequirement = computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);

            // get the flag for IM satisfied and return the available collateral balance
            uint256 availableCollateralBalance = 0;
            bool isIMSatisfied = false;
            if (collateralBalance >= initialMarginRequirement + highestUnrealizedLoss) {
                availableCollateralBalance = collateralBalance - initialMarginRequirement - highestUnrealizedLoss;
                isIMSatisfied = true;
            }

            return Account.MarginRequirement({
                isIMSatisfied: isIMSatisfied,
                isLMSatisfied: isLMSatisfied,
                initialMarginRequirement: initialMarginRequirement,
                liquidationMarginRequirement: liquidationMarginRequirement,
                highestUnrealizedLoss: highestUnrealizedLoss,
                availableCollateralBalance: availableCollateralBalance,
                collateralType: collateralType
            });
        }
    
        if (self.accountMode == Account.MULTI_TOKEN_MODE) {

            // get margin requirements and highest unrealized loss in USD terms
            uint256 liquidationMarginRequirementInUSD = 0;
            uint256 highestUnrealizedLossInUSD = 0;

            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);
                CollateralConfiguration.Data storage collateral = CollateralConfiguration.load(quoteToken);

                (uint256 liquidationMarginRequirementInCollateral, uint256 highestUnrealizedLossInCollateral) = 
                    getRequirementsAndHighestUnrealizedLossByCollateralType(self, quoteToken);

                liquidationMarginRequirementInUSD += collateral.getCollateralInUSD(liquidationMarginRequirementInCollateral);
                highestUnrealizedLossInUSD += collateral.getCollateralInUSD(highestUnrealizedLossInCollateral);
            }

            // compute the initial margin requirement in USD
            uint256 initialMarginRequirementInUSD = computeInitialMarginRequirement(liquidationMarginRequirementInUSD, imMultiplier);

            // get the account weighted balance in USD
            uint256 weightedCollateralBalanceInUSD = self.getWeightedCollateralBalanceInUSD();

            // compute the flag for LM satisfied
            bool isLMSatisfied = weightedCollateralBalanceInUSD >= liquidationMarginRequirementInUSD + highestUnrealizedLossInUSD;

            // get the flag for IM satisfied and get the available weighted collateral balance in USD
            uint256 availableWeightedUSDBalance = 0;
            bool isIMSatisfied = false;
            if (weightedCollateralBalanceInUSD >= initialMarginRequirementInUSD + highestUnrealizedLossInUSD) {
                isIMSatisfied = true;
                availableWeightedUSDBalance = 
                    weightedCollateralBalanceInUSD - initialMarginRequirementInUSD - highestUnrealizedLossInUSD;
            }

            if (collateralType == address(0)) {
                // return the USD amounts if the collateral type is zero address

                return Account.MarginRequirement({
                    isIMSatisfied: isIMSatisfied,
                    isLMSatisfied: isLMSatisfied,
                    initialMarginRequirement: initialMarginRequirementInUSD,
                    liquidationMarginRequirement: liquidationMarginRequirementInUSD,
                    highestUnrealizedLoss: highestUnrealizedLossInUSD,
                    availableCollateralBalance: weightedCollateralBalanceInUSD,
                    collateralType: collateralType
                });
            }
            else {
                // return the amounts in collateral if the collateral type is non-zero address
                CollateralConfiguration.Data storage collateral = CollateralConfiguration.load(collateralType);

                return Account.MarginRequirement({
                    isIMSatisfied: isIMSatisfied,
                    isLMSatisfied: isLMSatisfied,
                    initialMarginRequirement: collateral.getUSDInCollateral(initialMarginRequirementInUSD),
                    liquidationMarginRequirement: collateral.getUSDInCollateral(liquidationMarginRequirementInUSD),
                    highestUnrealizedLoss: collateral.getUSDInCollateral(highestUnrealizedLossInUSD),
                    availableCollateralBalance: collateral.getWeightedUSDInCollateral(availableWeightedUSDBalance),
                    collateralType: collateralType
                });
            }
        }

        revert UnsupportedAccountExposure(self.accountMode);
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
            Account.MakerMarketExposure[] memory makerExposures = 
                Market.exists(marketId).getAccountTakerAndMakerExposures(self.id);

            // Aggregate LMR and unrealized loss for all exposures
            for (uint256 j = 0; j < makerExposures.length; j++) {
                Account.MarketExposure memory exposureLower = makerExposures[j].lower;
                Account.MarketExposure memory exposureUpper = makerExposures[j].upper;

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

    function equalExposures(Account.MarketExposure memory a, Account.MarketExposure memory b) internal pure returns (bool) {
        if (
            a.annualizedNotional == b.annualizedNotional && 
            a.unrealizedLoss == b.unrealizedLoss
        ) {
            return true;
        }

        return false;
    }
}
