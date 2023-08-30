/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {AccountExposure} from "./AccountExposure.sol";
import {Account} from "../storage/Account.sol";
import {AutoExchangeConfiguration} from "../storage/AutoExchangeConfiguration.sol";
import {CollateralConfiguration} from "../storage/CollateralBubble.sol";
import {CollateralPool} from "../storage/CollateralPool.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { mulUDxUint, mulUDxInt, divUintUDx, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

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
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;

        // Single auto-exchange threshold check
        {
            (int256 accountValueOfCollateral, ) = 
                self.getRequirementDeltasByCollateralType(collateralType, imMultiplier);

            if (accountValueOfCollateral > 0) {
                return false;
            }

            CollateralConfiguration.ExchangeInfo memory exchange = 
                    CollateralConfiguration.getExchangeInfo(collateralPoolId, collateralType, address(0));

            int256 accountValueOfCollateralInUSD = 
                mulUDxInt(exchange.price.mul(exchange.exchangeHaircut), accountValueOfCollateral);

            if ((-accountValueOfCollateralInUSD).toUint() > autoExchangeConfig.singleAutoExchangeThresholdInUSD) {
                return true;
            }
        }

        // Get total account value in USD
        (int256 totalAccountValueInUSD, ) = self.getRequirementDeltasByBubble(address(0));

        // Get total negative account value in USD
        uint256 sumOfNegativeAccountValuesInUSD = 0;
        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];

            (int256 totalAccountValueOfQuoteToken, ) = 
                self.getRequirementDeltasByCollateralType(quoteTokens[i], imMultiplier);
            
            if (totalAccountValueOfQuoteToken < 0) {
                CollateralConfiguration.ExchangeInfo memory exchange = 
                    CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteToken, address(0));

                sumOfNegativeAccountValuesInUSD += 
                    mulUDxUint(exchange.price.mul(exchange.exchangeHaircut), (-totalAccountValueOfQuoteToken).toUint());
            }
        }
        
        if (sumOfNegativeAccountValuesInUSD > autoExchangeConfig.totalAutoExchangeThresholdInUSD) {
            return true;
        }

        if (totalAccountValueInUSD < 0) {
            // todo: decide on what to do when the account is liquidatable
        }

        if (
            sumOfNegativeAccountValuesInUSD > 
            mulUDxUint(autoExchangeConfig.negativeCollateralBalancesMultiplier, totalAccountValueInUSD.toUint())
        ) {
            return true;
        }

        return false;
    }

    function getMaxAmountToExchangeQuote(
        Account.Data storage self,
        address coveringToken,
        address autoexchangedToken
    ) internal view returns (uint256 /* coveringAmount */, uint256 /* autoexchangedAmount */ ) {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;

        (int256 accountValue, ) = 
            self.getRequirementDeltasByCollateralType(autoexchangedToken, imMultiplier);

        if (accountValue > 0) {
            return (0, 0);
        }

        uint256 amountToAutoExchange = mulUDxUint(
            AutoExchangeConfiguration.load().autoExchangeRatio,
            (-accountValue).toUint()
        );

        // todo: do we consider that we can use the entire collateral balance of covering token?
        uint256 coveringTokenAmount = self.getCollateralBalance(coveringToken);

        UD60x18 autoexchangeDiscount = 
            CollateralConfiguration.getAutoExchangeDiscount(collateralPoolId, coveringToken, autoexchangedToken);
        
        UD60x18 price = 
            CollateralConfiguration.getCollateralPriceInToken(collateralPoolId, coveringToken, autoexchangedToken);

        uint256 availableToAutoExchange = 
            mulUDxUint(price.mul(autoexchangeDiscount), coveringTokenAmount);
        
        if (availableToAutoExchange <= amountToAutoExchange) {
            return (coveringTokenAmount, availableToAutoExchange);
        }
        else {
            uint256 correspondingTokenCoveringAmount = divUintUDx(coveringTokenAmount, price.mul(autoexchangeDiscount));
            return (correspondingTokenCoveringAmount, amountToAutoExchange);
        }
    }
}
