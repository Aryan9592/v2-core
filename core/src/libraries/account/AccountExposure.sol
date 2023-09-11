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
import {mulUDxUint, mulUDxInt, UD60x18} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import {UNIT} from "@prb/math/UD60x18.sol";

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

    function getMarginInfoByBubble(Account.Data storage account, address token) 
        internal 
        view
        returns (Account.MarginInfo memory) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;
        UD60x18 mmrMultiplier = collateralPool.riskConfig.mmrMultiplier;
        UD60x18 dutchMultiplier = collateralPool.riskConfig.dutchMultiplier;
        UD60x18 adlMultiplier = collateralPool.riskConfig.adlMultiplier;

        address quoteToken = address(0);
        Account.MarginInfo memory marginInfo = computeMarginInfoByBubble(
            account,
            collateralPoolId,
            address(0),
            imMultiplier,
            mmrMultiplier,
            dutchMultiplier,
            adlMultiplier
        ); 

        if (token == quoteToken) {
            return marginInfo;
        }

        // Direct exchange rate
        CollateralConfiguration.ExchangeInfo memory exchange = 
            CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteToken, token);

        return Account.MarginInfo({
            collateralType: token,
            netDeposits: getExchangedQuantity(marginInfo.netDeposits, exchange.price, exchange.haircut),
            marginBalance: getExchangedQuantity(marginInfo.marginBalance, exchange.price, exchange.haircut),
            realBalance: getExchangedQuantity(marginInfo.realBalance, exchange.price, exchange.haircut),
            initialDelta: getExchangedQuantity(marginInfo.initialDelta, exchange.price, exchange.haircut),
            maintenanceDelta: getExchangedQuantity(marginInfo.maintenanceDelta, exchange.price, exchange.haircut),
            liquidationDelta: getExchangedQuantity(marginInfo.liquidationDelta, exchange.price, exchange.haircut),
            dutchDelta: getExchangedQuantity(marginInfo.dutchDelta, exchange.price, exchange.haircut),
            adlDelta: getExchangedQuantity(marginInfo.adlDelta, exchange.price, exchange.haircut)
        });
    }

    function computeMarginInfoByBubble(
        Account.Data storage account, 
        uint128 collateralPoolId, 
        address quoteToken, 
        UD60x18 imMultiplier,
        UD60x18 mmrMultiplier,
        UD60x18 dutchMultiplier,
        UD60x18 adlMultiplier
    ) 
        private 
        view
        returns(Account.MarginInfo memory marginInfo) 
    {
        marginInfo = getMarginInfoByCollateralType(
            account,
            quoteToken,
            imMultiplier,
            mmrMultiplier,
            dutchMultiplier,
            adlMultiplier
        );

        address[] memory tokens = CollateralConfiguration.exists(collateralPoolId, quoteToken).childTokens.values();

        // todo: why do we need to loop through the margin requirements of child tokens when only base tokens
        // can have margin requirements attached to them given only base tokens can be quite tokens for a given market?

        for (uint256 i = 0; i < tokens.length; i++) {
            Account.MarginInfo memory subMarginInfo  = 
                computeMarginInfoByBubble(
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

            marginInfo = Account.MarginInfo({
                collateralType: marginInfo.collateralType,
                netDeposits: marginInfo.netDeposits,
                marginBalance: 
                    marginInfo.marginBalance + 
                    getExchangedQuantity(subMarginInfo.marginBalance, price, haircut),
                realBalance: 
                    marginInfo.realBalance + 
                    getExchangedQuantity(subMarginInfo.realBalance, price, haircut),
                initialDelta: 
                    marginInfo.initialDelta + 
                    getExchangedQuantity(subMarginInfo.initialDelta, price, haircut),
                maintenanceDelta:
                    marginInfo.maintenanceDelta + 
                    getExchangedQuantity(subMarginInfo.maintenanceDelta, price, haircut),
                liquidationDelta: 
                    marginInfo.liquidationDelta + 
                    getExchangedQuantity(subMarginInfo.liquidationDelta, price, haircut),
                dutchDelta: 
                    marginInfo.dutchDelta + 
                    getExchangedQuantity(subMarginInfo.dutchDelta, price, haircut),
                adlDelta: 
                    marginInfo.adlDelta + 
                    getExchangedQuantity(subMarginInfo.adlDelta, price, haircut)
            });
        }
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirement deltas
     * @dev The amounts are in collateral type. 
     */
    function getMarginInfoByCollateralType(
        Account.Data storage self, 
        address collateralType,
        UD60x18 imMultiplier,
        UD60x18 mmrMultiplier,
        UD60x18 dutchMultiplier,
        UD60x18 adlMultiplier
    )
        internal
        view
        returns (Account.MarginInfo memory marginInfo)
    {
        uint256 liquidationMarginRequirement = 0;

        int256 accruedCashflows;
        int256 lockedPnL;
        int256 highestUnrealizedLoss = 0;

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

                accruedCashflows += exposureLower.pnlComponents.accruedCashflows;
                lockedPnL += exposureLower.pnlComponents.lockedPnL;

                uint256 lowerLMR = 
                    computeLiquidationMarginRequirement(exposureLower.annualizedNotional, riskParameter);

                if (equalExposures(exposureLower, exposureUpper)) {
                    liquidationMarginRequirement += lowerLMR;
                    highestUnrealizedLoss += SignedMath.min(exposureLower.pnlComponents.unrealizedPnL, 0);
                } else {
                    uint256 upperLMR = 
                    computeLiquidationMarginRequirement(exposureUpper.annualizedNotional, riskParameter);

                    if (
                        lowerLMR.toInt() + exposureLower.pnlComponents.unrealizedPnL >
                        upperLMR.toInt() + exposureUpper.pnlComponents.unrealizedPnL
                    ) {
                        liquidationMarginRequirement += lowerLMR;
                        highestUnrealizedLoss += SignedMath.min(exposureLower.pnlComponents.unrealizedPnL, 0);
                    } else {
                        liquidationMarginRequirement += upperLMR;
                        highestUnrealizedLoss += SignedMath.min(exposureUpper.pnlComponents.unrealizedPnL, 0);
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
        int256 netDeposits = self.getAccountNetCollateralDeposits(collateralType);

        int256 marginBalance = netDeposits + accruedCashflows + lockedPnL + highestUnrealizedLoss;
        int256 realBalance = netDeposits + accruedCashflows + lockedPnL;
        
        return Account.MarginInfo({
            collateralType: collateralType,
            netDeposits: netDeposits,
            marginBalance: marginBalance,
            realBalance: realBalance,
            initialDelta: marginBalance - initialMarginRequirement.toInt(),
            maintenanceDelta: marginBalance - maintenanceMarginRequirement.toInt(),
            liquidationDelta: marginBalance - liquidationMarginRequirement.toInt(),
            dutchDelta: marginBalance - dutchMarginRequirement.toInt(),
            adlDelta: marginBalance - adlMarginRequirement.toInt()
        });
    }

    function getExchangedQuantity(int256 quantity, UD60x18 price, UD60x18 haircut) 
    private 
    pure 
    returns (int256) {
        int256 sign = getSign(quantity);
        UD60x18 haircutPrice = price.mul((sign > 0) ? UNIT.sub(haircut) : UNIT.add(haircut));
        return mulUDxInt(haircutPrice, quantity);
    }

    function getSign(int256 value) private pure returns (int256) {
        return (value >= 0) ? int256(1) : -1;
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
            a.pnlComponents.accruedCashflows == b.pnlComponents.accruedCashflows &&
            a.pnlComponents.lockedPnL == b.pnlComponents.lockedPnL &&
            a.pnlComponents.unrealizedPnL == b.pnlComponents.unrealizedPnL
        ) {
            return true;
        }

        return false;
    }
}
