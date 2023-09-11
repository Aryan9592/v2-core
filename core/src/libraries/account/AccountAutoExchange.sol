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
import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";
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

        // Single auto-exchange threshold check
        {
            Account.MarginRequirementDeltas memory deltas =
                self.getRequirementDeltasByCollateralType(collateralType,
                    collateralPool.riskConfig.imMultiplier,
                    collateralPool.riskConfig.mmrMultiplier);

            if (deltas.initialDelta > 0) {
                return false;
            }

            UD60x18 price = 
                CollateralConfiguration.getExchangeInfo(collateralPoolId, collateralType, address(0)).price;

            int256 accountValueOfCollateralInUSD = 
                mulUDxInt(price, deltas.initialDelta);

            if ((-accountValueOfCollateralInUSD).toUint() > autoExchangeConfig.singleAutoExchangeThresholdInUSD) {
                return true;
            }
        }

        // Get total account value in USD
        int256 totalAccountValueInUSD = 0;
        {
            Account.MarginRequirementDeltas memory deltas = self.getRequirementDeltasByBubble(address(0));
            totalAccountValueInUSD = deltas.initialDelta;
        }

        // Get total negative account value in USD
        uint256 sumOfNegativeAccountValuesInUSD = 0;
        address[] memory quoteTokens = self.activeQuoteTokens.values();

        for (uint256 i = 0; i < quoteTokens.length; i++) {
            address quoteToken = quoteTokens[i];

            Account.MarginRequirementDeltas memory deltas = 
                self.getRequirementDeltasByCollateralType(
                    quoteToken,
                    collateralPool.riskConfig.imMultiplier,
                    collateralPool.riskConfig.mmrMultiplier);
            
            if (deltas.initialDelta < 0) {
                UD60x18 price = 
                    CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteToken, address(0)).price;

                sumOfNegativeAccountValuesInUSD += 
                    mulUDxUint(price, (-deltas.initialDelta).toUint());
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
        address autoExchangedToken
    ) internal view returns (uint256 /* coveringAmount */, uint256 /* autoExchangedAmount */ ) {

        CollateralPool.Data storage collateralPool = self.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;
        UD60x18 mmrMultiplier = collateralPool.riskConfig.mmrMultiplier;

        Account.MarginRequirementDeltas memory deltas = 
            self.getRequirementDeltasByCollateralType(autoExchangedToken, imMultiplier, mmrMultiplier);

        if (deltas.initialDelta > 0) {
            return (0, 0);
        }

        uint256 amountToAutoExchange = mulUDxUint(
            AutoExchangeConfiguration.load().autoExchangeRatio,
            (-deltas.initialDelta).toUint()
        );

        // todo: do we consider that we can use the entire collateral balance of covering token?
        uint256 coveringTokenAmount = self.getCollateralBalance(coveringToken);

        // todo: replace auto-exchange discount with the liquidation logic
        UD60x18 autoExchangeDiscount = UNIT;
        
        UD60x18 price = 
            CollateralConfiguration.getExchangeInfo(collateralPoolId, coveringToken, autoExchangedToken).price;

        uint256 availableToAutoExchange = 
            mulUDxUint(price.mul(autoExchangeDiscount), coveringTokenAmount);
        
        if (availableToAutoExchange <= amountToAutoExchange) {
            return (coveringTokenAmount, availableToAutoExchange);
        }
        else {
            uint256 correspondingTokenCoveringAmount = divUintUD(coveringTokenAmount, price.mul(autoExchangeDiscount));
            return (correspondingTokenCoveringAmount, amountToAutoExchange);
        }
    }
}
