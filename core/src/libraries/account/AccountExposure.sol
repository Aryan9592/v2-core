/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {Market} from "../../storage/Market.sol";

import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {mulUDxUint, mulUDxInt, UD60x18, divIntUD} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

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
        returns (Account.MarginRequirementDeltas memory deltas) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;
        UD60x18 mmrMultiplier = collateralPool.riskConfig.mmrMultiplier;
        UD60x18 dutchMultiplier = collateralPool.riskConfig.dutchMultiplier;
        UD60x18 adlMultiplier = collateralPool.riskConfig.adlMultiplier;

        // multi-token mode by default
        Account.MarginRequirementDeltas memory deltasInUSD =
            computeRequirementDeltasByBubble(
                account,
                collateralPoolId,
                address(0),
                imMultiplier,
                mmrMultiplier,
                dutchMultiplier,
                adlMultiplier
            );

        if (baseToken == address(0)) {
            return deltasInUSD;
        }

        CollateralConfiguration.ExchangeInfo memory exchange =
            CollateralConfiguration.getExchangeInfo(collateralPoolId, baseToken, address(0));

        int256 initialDelta = divIntUD(deltasInUSD.initialDelta, exchange.price.mul(exchange.haircut));
        int256 maintenanceDelta = divIntUD(deltasInUSD.maintenanceDelta, exchange.price.mul(exchange.haircut));
        int256 liquidationDelta = divIntUD(deltasInUSD.liquidationDelta, exchange.price.mul(exchange.haircut));
        int256 dutchDelta = divIntUD(deltasInUSD.dutchDelta, exchange.price.mul(exchange.haircut));
        int256 adlDelta = divIntUD(deltasInUSD.adlDelta, exchange.price.mul(exchange.haircut));

        return Account.MarginRequirementDeltas({
            initialDelta: initialDelta,
            liquidationDelta: liquidationDelta,
            maintenanceDelta: maintenanceDelta,
            dutchDelta: dutchDelta,
            adlDelta: adlDelta,
            collateralType: baseToken
        });


        revert UnsupportedAccountExposure(account.accountMode);
    }

    function computeRequirementDeltasByBubble(
        Account.Data storage account, 
        uint128 collateralPoolId, 
        address baseToken, 
        UD60x18 imMultiplier,
        UD60x18 mmrMultiplier,
        UD60x18 dutchMultiplier,
        UD60x18 adlMultiplier
    ) 
        private 
        view
        returns(Account.MarginRequirementDeltas memory deltas) 
    {
        deltas = getRequirementDeltasByCollateralType(
            account,
            baseToken,
            imMultiplier,
            mmrMultiplier,
            dutchMultiplier,
            adlMultiplier
        );

        address[] memory tokens = CollateralConfiguration.exists(collateralPoolId, baseToken).childTokens.values();

        // todo: why do we need to loop through the margin requirements of child tokens when only base tokens
        // can have margin requirements attached to them given only base tokens can be quite tokens for a given market?

        for (uint256 i = 0; i < tokens.length; i++) {
            Account.MarginRequirementDeltas memory subMR = 
                computeRequirementDeltasByBubble(
                    account,
                    collateralPoolId,
                    tokens[i],
                    imMultiplier,
                    mmrMultiplier,
                    dutchMultiplier,
                    adlMultiplier
                );

            CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralPoolId, tokens[i]);
            UD60x18 price = collateral.getParentPrice();
            UD60x18 haircut = collateral.parentConfig.exchangeHaircut;

            // todo: similar if/else patterns, consider abstracting into a helper method
            if (subMR.initialDelta <= 0) {
                deltas.initialDelta += mulUDxInt(price, subMR.initialDelta);
            }
            else {
                deltas.initialDelta += mulUDxInt(price.mul(haircut), subMR.initialDelta);
            }

            if (subMR.maintenanceDelta <= 0) {
                deltas.maintenanceDelta += mulUDxInt(price, subMR.maintenanceDelta);
            }
            else {
                deltas.maintenanceDelta += mulUDxInt(price.mul(haircut), subMR.maintenanceDelta);
            }

            if (subMR.liquidationDelta <= 0) {
                deltas.liquidationDelta += mulUDxInt(price, subMR.liquidationDelta);
            }
            else {
                deltas.liquidationDelta += mulUDxInt(price.mul(haircut), subMR.liquidationDelta);
            }

            if (subMR.dutchDelta <= 0) {
                deltas.dutchDelta += mulUDxInt(price, subMR.dutchDelta);
            }
            else {
                deltas.dutchDelta += mulUDxInt(price.mul(haircut), subMR.dutchDelta);
            }

            if (subMR.adlDelta <= 0) {
                deltas.adlDelta += mulUDxInt(price, subMR.adlDelta);
            }
            else {
                deltas.adlDelta += mulUDxInt(price.mul(haircut), subMR.adlDelta);
            }
        }
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirement deltas
     * @dev The amounts are in collateral type. 
     */
    function getRequirementDeltasByCollateralType(
        Account.Data storage self, 
        address collateralType,
        UD60x18 imMultiplier,
        UD60x18 mmrMultiplier,
        UD60x18 dutchMultiplier,
        UD60x18 adlMultiplier
    )
        internal
        view
        returns (Account.MarginRequirementDeltas memory)
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
        uint256 initialMarginRequirement = mulUDxUint(imMultiplier, liquidationMarginRequirement);

        // Get the maintenance margin requirement
        uint256 maintenanceMarginRequirement  = mulUDxUint(mmrMultiplier, liquidationMarginRequirement);

        // Get the dutch margin requirement
        uint256 dutchMarginRequirement  = mulUDxUint(dutchMultiplier, liquidationMarginRequirement);

        // Get the adl margin requirement
        uint256 adlMarginRequirement  = mulUDxUint(adlMultiplier, liquidationMarginRequirement);

        // Get the collateral balance of the account in this specific collateral
        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        // Compute and return the initial and liquidation deltas

        // todo: make sure when we're adding the highestUnrealizedLoss it's only from unfilled orders
        // filled orders should be taken care of in the balance calculations

        int256 initialDelta = collateralBalance.toInt() - (initialMarginRequirement + highestUnrealizedLoss).toInt();
        int256 maintenanceDelta = collateralBalance.toInt() - (maintenanceMarginRequirement + highestUnrealizedLoss).toInt();
        int256 liquidationDelta = collateralBalance.toInt() - (liquidationMarginRequirement + highestUnrealizedLoss).toInt();
        int256 dutchDelta = collateralBalance.toInt() - (dutchMarginRequirement + highestUnrealizedLoss).toInt();
        int256 adlDelta = collateralBalance.toInt() - (adlMarginRequirement + highestUnrealizedLoss).toInt();

        return Account.MarginRequirementDeltas({
            initialDelta: initialDelta,
            maintenanceDelta: maintenanceDelta,
            liquidationDelta: liquidationDelta,
            dutchDelta: dutchDelta,
            adlDelta: adlDelta,
            collateralType: collateralType
        });
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
