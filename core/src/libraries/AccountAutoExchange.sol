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

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
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
        address quoteType
    ) internal view returns (bool) {

        if(self.accountMode == Account.SINGLE_TOKEN_MODE) {
            return false;
        }

        int256 accountValueBySettlementType = self.getAccountValueByCollateralType(quoteType);

        if (accountValueBySettlementType > 0) {
            return false;
        }

        AutoExchangeConfiguration.Data memory autoExchangeConfig = 
            AutoExchangeConfiguration.load();

        if ((-accountValueBySettlementType).toUint() > autoExchangeConfig.singleAutoExchangeThresholdInUSD) {
            return true;
        }

        uint256 sumOfNegativeAccountValuesInUSD;
        int256 totalAccountValueInUSD;
        for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
            address collateralType = self.activeQuoteTokens.valueAt(i);
            int256 accountValueByCollateralTypeInUSD = self.getAccountValueByCollateralTypeInUSD(collateralType);
            sumOfNegativeAccountValuesInUSD += accountValueByCollateralTypeInUSD < 0 ?
                (-accountValueByCollateralTypeInUSD).toUint() : 0;
            totalAccountValueInUSD += accountValueByCollateralTypeInUSD;
        }
        // note: activeQuoteTokens does not include collateral tokens 
        // that are not collaterals of active markets. These also count towards totalAccountValueInUSD
        for (uint256 i = 1; i <= self.activeCollaterals.length(); i++) {
            address collateralType = self.activeCollaterals.valueAt(i);
            if (!self.activeQuoteTokens.contains(collateralType)) {
                int256 accountValueByCollateralTypeInUSD = self.getAccountValueByCollateralTypeInUSD(collateralType);
                totalAccountValueInUSD += accountValueByCollateralTypeInUSD;
            }
        }
        
        if (sumOfNegativeAccountValuesInUSD > autoExchangeConfig.totalAutoExchangeThresholdInUSD) {
            return true;
        }

        // todo: this will fail if totalAccountValueInUSDis negative. decide on action.
        if (
            sumOfNegativeAccountValuesInUSD > 
            mulUDxUint(autoExchangeConfig.negativeCollateralBalancesMultiplier, totalAccountValueInUSD.toUint())
        ) {
            return true;
        }

        return false;
    }

    function getAccountValueByCollateralType(
        Account.Data storage self,
        address collateralType
    ) internal view returns (int256 accountValue) {
        // (uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss) = 
        //     AccountExposure.getRequirementsAndHighestUnrealizedLossByCollateralType(self, collateralType);

        // UD60x18 imMultiplier = self.getCollateralPool().riskConfig.imMultiplier;
        // uint256 initialMarginRequirement = 
        //     AccountExposure.computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);

        // accountValue = self.getCollateralBalance(collateralType).toInt() - 
        //     highestUnrealizedLoss.toInt() - 
        //     initialMarginRequirement.toInt();

        return 0;
    }

    function getAccountValueByCollateralTypeInUSD(
        Account.Data storage self,
        address collateralType
    ) internal view returns (int256) {
        // todo

        return 0;

        // int256 accountValueByCollateralType = self.getAccountValueByCollateralType(collateralType);

        // uint256 accountValueByCollateralTypeInUSD = CollateralConfiguration.exists(collateralType)
        //     .getCollateralInUSD(
        //         accountValueByCollateralType > 0 ? 
        //             accountValueByCollateralType.toUint() :
        //             (-accountValueByCollateralType).toUint()
        //     );

        // return accountValueByCollateralType > 0 ? accountValueByCollateralTypeInUSD.toInt() :
        //     -accountValueByCollateralTypeInUSD.toInt();
    }
}
