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
import { UD60x18, UNIT, fromUD60x18 } from "@prb/math/UD60x18.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/*
TODOs
    - consider splitting isEligibleForAutoExchange into smaller helpers
    - make sure the parent of the collateral type in eligibility check is dollar -> means it's a centroid of a
    bubble? -> in any case for yield-bearing assets this condition should not in theory be breached
    - consider introducing a separate getCollateralInfoByCollateralType to avoid extra gas cost for eligibility calc
    where that's not necessary
    - get rid of auto-exchange ratio to keep complexity lower
    - consider ways to avoid nested if blocks
    - bring auto-exchange discounts
    - check token decimals in max amount calc!
    - consider splitting getMaxAmountToExchangeQuote into smaller helpers similar to aave v3
    ref: https://github.com/aave/aave-v3-core/blob/master/contracts/protocol/libraries/logic/LiquidationLogic.sol
    - getExchangeInfo shouldn't use haircuts...
    - check if division by ae discount works
*/


/**
 * @title Object for managing account auto-echange utilities.
 */
library AccountAutoExchange {
    using AccountAutoExchange for Account.Data;
    using Account for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;

    function isEligibleForAutoExchange(
        Account.Data storage self,
        address collateralType
    ) internal view returns (bool) {
        AutoExchangeConfiguration.Data memory autoExchangeConfig = AutoExchangeConfiguration.load();

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;

        {
            Account.MarginInfo memory marginInfo =
                self.getMarginInfoByCollateralType(
                    collateralType,
                    collateralPool.riskConfig.riskMultipliers
                );

            // mismatched margin coverage check

            Account.MarginInfo memory overallMarginInfo = self.getMarginInfoByBubble(address(0));

            if ( (overallMarginInfo.maintenanceDelta < 0) && (marginInfo.liquidationDelta < 0) ) {
                return true;
            }

            // Single auto-exchange threshold check

            if (marginInfo.collateralInfo.marginBalance > 0) {
                return false;
            }

            UD60x18 price = 
                CollateralConfiguration.getExchangeInfo(collateralPoolId, collateralType, address(0)).price;

            int256 marginBalanceOfCollateralInUSD =
                mulUDxInt(price, marginInfo.collateralInfo.marginBalance);

            if ((-marginInfo.collateralInfo.marginBalance).toUint() >
                CollateralConfiguration.load(
                collateralPoolId,
                collateralType
            ).baseConfig.autoExchangeThreshold) {
                return true;
            }

        }

        // Get total negative account value in USD
        uint256 sumOfNegativeAccountValuesInUSD = 0;
        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            // todo: rename deltas to smth more meaningful
            Account.MarginInfo memory deltas =
                self.getMarginInfoByCollateralType(
                    quoteTokens[i],
                    collateralPool.riskConfig.riskMultipliers
                );
            
            if (deltas.collateralInfo.marginBalance < 0) {
                // todo: layer in the haircut in here (via a helper?)
                UD60x18 price = 
                    CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteTokens[i], address(0)).price;

                sumOfNegativeAccountValuesInUSD += 
                    mulUDxUint(price, (-deltas.collateralInfo.marginBalance).toUint());
            }
        }
        
        if (sumOfNegativeAccountValuesInUSD > autoExchangeConfig.totalAutoExchangeThresholdInUSD) {
            return true;
        }


        // Get total account value in USD
        int256 totalAccountValueInUSD = 0;
        {
            Account.MarginInfo memory marginInfo = self.getMarginInfoByBubble(address(0));
            totalAccountValueInUSD = marginInfo.collateralInfo.marginBalance;
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
        uint256 amountToAutoExchangeQuote
    ) private view returns (uint256 amountToAutoExchange) {

        Account.MarginInfo memory marginInfo =
        self.getMarginInfoByCollateralType(
            quoteToken,
            collateralPool.riskConfig.riskMultipliers
        );

        Account.MarginInfo memory overallMarginInfo = self.getMarginInfoByBubble(address(0));

        if (overallMarginInfo.maintenanceDelta < 0 ) {

            if (marginInfo.liquidationDelta > 0) {
                return 0;
            }

            amountToAutoExchange = (-marginInfo.liquidationDelta).toUint();

        } else {

            if (marginInfo.collateralInfo.marginBalance > 0) {
                return 0;
            }

            amountToAutoExchange = (-marginInfo.collateralInfo.marginBalance).toUint();

        }

        if (amountToAutoExchangeQuote < amountToAutoExchange) {
            amountToAutoExchange = amountToAutoExchangeQuote;
        }


        return amountToAutoExchange;
    }

    function calculateAvailableCollateral(
        Account.Data storage self,
        CollateralPool.Data storage collateralPool,
        address collateralToken
    ) private view returns (uint256) {

        // note, don't need risk multipliers to get real balance
        Account.MarginInfo memory marginInfo = self.getMarginInfoByCollateralType(
            collateralToken,
            collateralPool.riskConfig.riskMultipliers
        );

        return marginInfo.collateralInfo.realBalance.toUint();

    }

    function calculateAvailableCollateralToAutoExchange(
        Account.Data storage self,
        address collateralToken,
        address quoteToken,
        uint256 amountToAutoExchangeQuote
    ) internal view returns (
        uint256 /* collateralAmountToLiquidator */, uint256 /* collateralAmountToIF */, uint256 /* quoteAmount */
    ) {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;

        uint256 quoteToCover = calculateQuoteToCover(self, collateralPool, quoteToken, amountToAutoExchangeQuote);

        if (quoteToCover == 0) {
            return (0, 0, 0);
        }

        UD60x18 autoExchangeBonus = UNIT;

        UD60x18 priceQuoteToCollateral = CollateralConfiguration.getExchangeInfo(
            collateralPoolId,
            quoteToken,
            collateralToken
        ).price;

        // This is the base collateral to liquidate based on the given quote to cover
        uint256 baseCollateral = mulUDxUint(priceQuoteToCollateral, quoteToCover);

        uint256 collateralToLiquidate = mulUDxUint(autoExchangeBonus, baseCollateral);

        uint256 availableCollateral = calculateAvailableCollateral(self, collateralPool, collateralToken);

        if (collateralToLiquidate > availableCollateral) {

            collateralToLiquidate = availableCollateral;
            UD60x18 priceCollateralToQuote = CollateralConfiguration.getExchangeInfo(
                collateralPoolId,
                collateralToken,
                quoteToken
            ).price;
            quoteToCover = divUintUD(mulUDxUint(priceCollateralToQuote, collateralToLiquidate), autoExchangeBonus);
        }

        UD60x18 autoExchangeInsuranceFee = CollateralConfiguration.load(
            collateralPoolId,
            quoteToken
        ).baseConfig.autoExchangeInsuranceFee;


        if (fromUD60x18(autoExchangeInsuranceFee) != 0) {

            uint256 bonusCollateral = collateralToLiquidate - divUintUD(collateralToLiquidate, autoExchangeBonus);
            uint256 insuranceFundFee = mulUDxUint(autoExchangeInsuranceFee, bonusCollateral);

            return (
                collateralToLiquidate - insuranceFundFee,
                insuranceFundFee,
                quoteToCover
            );

        }

        return (
            collateralToLiquidate,
            0,
            quoteToCover
        );

    }
}
