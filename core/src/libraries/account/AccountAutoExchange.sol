/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../../storage/Account.sol";
import {AutoExchangeConfiguration} from "../../storage/AutoExchangeConfiguration.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { mulUDxUint, mulUDxInt, divUintUD } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, UNIT, unwrap } from "@prb/math/UD60x18.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {AccountExposure} from "./AccountExposure.sol";

/**
 * @title Object for managing account auto-exchange utilities.
 */
library AccountAutoExchange {
    using AccountAutoExchange for Account.Data;
    using Account for Account.Data;
    using AccountExposure for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;


    // todo: consider breaking up this into two functions
    // isChild
    // isWithinBubbleCoverageExhausted
    function isWithinBubbleCoverageExhausted(
        Account.Data storage self,
        address quoteType,
        address collateralType
    ) internal view returns (bool) {

        bool childrenBalanceExhausted = true;

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        address[] memory tokens = CollateralConfiguration.exists(collateralPoolId, quoteType).childTokens.values();

        // todo: consider running two loops, one for checking for collateralType == tokens[i]
        // and the other one for checking the dust threshold

        for (uint256 i = 0; i < tokens.length; i++) {

            if (collateralType == tokens[i]) {
                return true;
            }

            uint256 autoExchangeDustThreshold = CollateralConfiguration.load(
                collateralPoolId,
                tokens[i]
            ).baseConfig.autoExchangeDustThreshold;

            int256 netDeposits = self.getAccountNetCollateralDeposits(tokens[i]);

            if (netDeposits > autoExchangeDustThreshold.toInt()) {
                childrenBalanceExhausted = false;
            }

        }

        return childrenBalanceExhausted;
    }

    function isEligibleForAutoExchange(
        Account.Data storage self,
        address collateralType
    ) internal view returns (bool) {
        AutoExchangeConfiguration.Data memory autoExchangeConfig = AutoExchangeConfiguration.load();

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;

        Account.MarginInfo memory overallMarginInfo = self.getMarginInfoByBubble(address(0));

        {
            Account.MarginInfo memory marginInfo =
                self.getMarginInfoByCollateralType(
                    collateralType,
                    collateralPool.riskConfig.riskMultipliers
                );

            // mismatched margin coverage check

            if ( (overallMarginInfo.maintenanceDelta < 0) && (marginInfo.liquidationDelta < 0) ) {
                return true;
            }

            // Single auto-exchange threshold check



            if (marginInfo.collateralInfo.marginBalance > 0) {
                // We make sure to return false in this case to avoid the scenario where the
                // second and third conditions below end up being true (stemming from deficits) in other
                // tokens
                return false;
            }

            if (
                (-marginInfo.collateralInfo.marginBalance).toUint() >
                CollateralConfiguration.load(
                    collateralPoolId,
                    collateralType
                ).baseConfig.autoExchangeThreshold
            ) {
                return true;
            }

        }

        // Get total negative account value in USD
        uint256 sumOfNegativeAccountValuesInUSD = 0;

        // Note, in order to get the sum of negative balances, we don't need to loop through yield-bearing
        // tokens since they will never have a negative balance

        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            Account.CollateralInfo memory collateralInfo =
                self.getCollateralInfoByCollateralType(
                    quoteTokens[i]
                );
            
            if (collateralInfo.marginBalance < 0) {

                CollateralConfiguration.ExchangeInfo memory exchangeInfo =
                CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteTokens[i], address(0));

                UD60x18 haircutPrice = exchangeInfo.price.mul(UNIT.add(exchangeInfo.priceHaircut));

                sumOfNegativeAccountValuesInUSD += 
                    mulUDxUint(haircutPrice, (-collateralInfo.marginBalance).toUint());
            }
        }
        
        if (sumOfNegativeAccountValuesInUSD > autoExchangeConfig.totalAutoExchangeThresholdInUSD) {
            return true;
        }

        // Get total account value in USD
        int256 totalAccountValueInUSD = overallMarginInfo.rawInfo.rawMarginBalance;

        if (totalAccountValueInUSD < 0) {
            return true;
        }

        if (
            sumOfNegativeAccountValuesInUSD > 
            mulUDxUint(autoExchangeConfig.negativeCollateralBalancesMultiplier, totalAccountValueInUSD.toUint())
        ) {
            return true;
        }

        return false;
    }

    function calculateQuoteToCover(
        Account.Data storage self,
        CollateralPool.Data storage collateralPool,
        address quoteToken,
        uint256 requestedQuoteAmount,
        UD60x18 autoExchangeInsuranceFee
    ) private view returns (uint256 amountToAutoExchange) {

        Account.MarginInfo memory overallMarginInfo = self.getMarginInfoByBubble(address(0));

        if (overallMarginInfo.maintenanceDelta < 0 ) {

            int256 liquidationDelta = self.getMarginInfoByCollateralType(
                quoteToken,
                collateralPool.riskConfig.riskMultipliers
            ).liquidationDelta;

            if (liquidationDelta > 0) {
                return 0;
            }

            amountToAutoExchange = (-liquidationDelta).toUint();

        } else {

            int256 marginBalance = self.getCollateralInfoByCollateralType(
                quoteToken
            ).marginBalance;

            if (marginBalance > 0) {
                return 0;
            }

            amountToAutoExchange = (-marginBalance).toUint();

        }

        AutoExchangeConfiguration.Data memory autoExchangeConfig = AutoExchangeConfiguration.load();

        amountToAutoExchange = mulUDxUint(autoExchangeConfig.quoteBufferMultiplier, amountToAutoExchange);

        if (unwrap(autoExchangeInsuranceFee) != 0) {
            amountToAutoExchange = divUintUD(amountToAutoExchange, UNIT.sub(autoExchangeInsuranceFee));
        }


        if (requestedQuoteAmount > amountToAutoExchange) {
            amountToAutoExchange = requestedQuoteAmount;
        }


        return amountToAutoExchange;
    }

    function calculateAvailableCollateral(
        Account.Data storage self,
        address collateralToken
    ) private view returns (uint256 availableCollateral) {

        int256 realBalanceCollateralToken = self.getCollateralInfoByCollateralType(
            collateralToken
        ).realBalance;

        Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(collateralToken);
        int256 bbalLMRDelta =
            marginInfo.rawInfo.rawMarginBalance - marginInfo.rawInfo.rawLiquidationMarginRequirement.toInt();

        if (realBalanceCollateralToken > bbalLMRDelta) {
            availableCollateral = realBalanceCollateralToken > 0 ? realBalanceCollateralToken.toUint() : 0;
        } else {
            availableCollateral = bbalLMRDelta > 0 ? bbalLMRDelta.toUint() : 0;
        }

        return availableCollateral;
    }

    struct CalculateAvailableCollateralToAutoExchangeVars {
        UD60x18 autoExchangeInsuranceFee;
        uint256 quoteToCover;
        CollateralConfiguration.ExchangeInfo quoteToCollateralExchangeInfo;
        UD60x18 autoExchangeBonus;
        UD60x18 priceQuoteToCollateral;
        uint256 collateralToLiquidate;
        uint256 availableCollateral;

    }

    // todo: rename to calculateAutoExchangeAmounts
    function calculateAvailableCollateralToAutoExchange(
        Account.Data storage self,
        address collateralToken,
        address quoteToken,
        uint256 amountToAutoExchangeQuote
    ) internal view returns (
        uint256 /* collateralAmountToLiquidator */,
        uint256 /* quoteAmountToInsuranceFund */,
        uint256 /* quoteAmountToAccount */
    ) {

        CalculateAvailableCollateralToAutoExchangeVars memory vars;

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        vars.autoExchangeInsuranceFee = CollateralConfiguration.load(
            collateralPool.id,
            quoteToken
        ).baseConfig.autoExchangeInsuranceFee;

        vars.quoteToCover = calculateQuoteToCover(
            self,
            collateralPool,
            quoteToken,
            amountToAutoExchangeQuote,
            vars.autoExchangeInsuranceFee
        );

        if (vars.quoteToCover == 0) {
            return (0, 0, 0);
        }

        vars.quoteToCollateralExchangeInfo = CollateralConfiguration.getExchangeInfo(
            collateralPool.id,
            quoteToken,
            collateralToken
        );

        vars.autoExchangeBonus = UNIT.add(vars.quoteToCollateralExchangeInfo.autoExchangeDiscount);

        vars.priceQuoteToCollateral = vars.quoteToCollateralExchangeInfo.price;

        // This is the base collateral to liquidate based on the given quote to cover
        vars.collateralToLiquidate = mulUDxUint(
            vars.autoExchangeBonus,
            mulUDxUint(vars.priceQuoteToCollateral, vars.quoteToCover)
        );

        vars.availableCollateral = calculateAvailableCollateral(self, collateralToken);

        if (vars.collateralToLiquidate > vars.availableCollateral) {

            vars.collateralToLiquidate = vars.availableCollateral;
            UD60x18 priceCollateralToQuote = CollateralConfiguration.getExchangeInfo(
                collateralPool.id,
                collateralToken,
                quoteToken
            ).price;
            vars.quoteToCover = divUintUD(
                mulUDxUint(priceCollateralToQuote, vars.collateralToLiquidate),
                vars.autoExchangeBonus
            );
        }


        if (unwrap(vars.autoExchangeInsuranceFee) != 0) {

            uint256 insuranceFundFee = mulUDxUint(vars.autoExchangeInsuranceFee, vars.quoteToCover);

            return (
                vars.collateralToLiquidate,
                insuranceFundFee,
                vars.quoteToCover - insuranceFundFee
            );

        }

        return (
            vars.collateralToLiquidate,
            0,
            vars.quoteToCover
        );

    }
}
