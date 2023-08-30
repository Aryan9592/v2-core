/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {CollateralConfiguration} from "../storage/CollateralBubble.sol";
import {CollateralPool} from "../storage/CollateralPool.sol";
import {Market} from "../storage/Market.sol";

import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {mulUDxUint, mulUDxInt, UD60x18, divIntUDx} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

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

    function getRequirementDeltasByBubble(Account.Data storage account, address baseToken) 
        internal 
        view
        returns (int256 /* initialDelta */, int256 /* liquidationDelta */) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;

        if (account.accountMode == Account.SINGLE_TOKEN_MODE) {
            return computeRequirementDeltasByBubble(account, collateralPoolId, baseToken, imMultiplier); 
        }

        if (account.accountMode == Account.MULTI_TOKEN_MODE) {
            (int256 initialDeltaInUSD, int256 liquidationDeltaInUSD) = 
                computeRequirementDeltasByBubble(account, collateralPoolId, address(0), imMultiplier); 

            if (baseToken == address(0)) {
                return (initialDeltaInUSD, liquidationDeltaInUSD);
            }

            CollateralConfiguration.ExchangeInfo memory exchange = 
                CollateralConfiguration.getExchangeInfo(collateralPoolId, baseToken, address(0));
                
            int256 initialDelta = divIntUDx(initialDeltaInUSD, exchange.price.mul(exchange.exchangeHaircut));
            int256 liquidationDelta = divIntUDx(liquidationDeltaInUSD, exchange.price.mul(exchange.exchangeHaircut));
            
            return (initialDelta, liquidationDelta);
        }

        revert UnsupportedAccountExposure(account.accountMode);
    }

    function computeRequirementDeltasByBubble(
        Account.Data storage account, 
        uint128 collateralPoolId, 
        address baseToken, 
        UD60x18 imMultiplier
    ) 
        private 
        view
        returns(int256 initialDelta, int256 liquidationDelta) 
    {
        (initialDelta, liquidationDelta) = getRequirementDeltasByCollateralType(account, baseToken, imMultiplier);

        address[] memory tokens = CollateralConfiguration.exists(collateralPoolId, baseToken).childTokens.values();

        for (uint256 i = 0; i < tokens.length; i++) {
            (int256 subInitialDelta, int256 subLiquidationDelta) = 
                computeRequirementDeltasByBubble(account, collateralPoolId, tokens[i], imMultiplier);

            UD60x18 price = CollateralConfiguration.getCollateralPriceInToken(collateralPoolId, tokens[i], baseToken);
            UD60x18 haircut = CollateralConfiguration.exists(collateralPoolId, tokens[i]).parentConfig.exchangeHaircut;

            if (subInitialDelta <= 0) {
                initialDelta += mulUDxInt(price, subInitialDelta);
            }
            else {
                initialDelta += mulUDxInt(price.mul(haircut), subInitialDelta);
            }

            if (subLiquidationDelta <= 0) {
                liquidationDelta += mulUDxInt(price, subLiquidationDelta);
            }
            else {
                liquidationDelta += mulUDxInt(price.mul(haircut), subLiquidationDelta);
            }
        }

        return (initialDelta, liquidationDelta);
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirement deltas
     * @dev The amounts are in collateral type. 
     */
    function getRequirementDeltasByCollateralType(
        Account.Data storage self, 
        address collateralType,
        UD60x18 imMultiplier
    )
        internal
        view
        returns (int256 initialDelta, int256 liquidationDelta)
    {
        uint256 liquidationMarginRequirement = 0;
        uint256 highestUnrealizedLoss = 0;

        uint256[] memory markets = self.activeMarketsPerQuoteToken[collateralType].values();

        for (uint256 i = 0; i < markets.length; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            // Get the risk parameter of the market
            UD60x18 riskParameter = market.riskConfig.riskParameter;

            // Get taker and maker exposure to the market
            Account.MakerMarketExposure[] memory makerExposures = 
                market.getAccountTakerAndMakerExposures(self.id);

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

        // Get the initial margin requirement
        uint256 initialMarginRequirement = computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);

        // Get the collateral balance of the account in this specific collateral
        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        // Compute and return the initial and liquidation deltas
        initialDelta = collateralBalance.toInt() - (initialMarginRequirement + highestUnrealizedLoss).toInt();
        liquidationDelta = collateralBalance.toInt() - (liquidationMarginRequirement + highestUnrealizedLoss).toInt();
    }

    /**
     * @dev Returns the liquidation margin requirement given the annualized exposure and the risk parameter
     */
    function computeLiquidationMarginRequirement(int256 annualizedNotional, UD60x18 riskParameter)
    private
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
    private
    pure
    returns (uint256 initialMarginRequirement)
    {
        initialMarginRequirement = mulUDxUint(imMultiplier, liquidationMarginRequirement);
    }

    function equalExposures(Account.MarketExposure memory a, Account.MarketExposure memory b) 
    private 
    pure 
    returns (bool) 
    {
        if (
            a.annualizedNotional == b.annualizedNotional && 
            a.unrealizedLoss == b.unrealizedLoss
        ) {
            return true;
        }

        return false;
    }
}
