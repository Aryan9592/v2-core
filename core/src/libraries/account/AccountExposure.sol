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

import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {mulUDxUint, mulUDxInt, mulSDxInt, UD60x18} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { sd, unwrap, SD59x18 } from "@prb/math/SD59x18.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";
import {UNIT, ZERO} from "@prb/math/UD60x18.sol";

/**
 * @title Object for tracking account margin requirements.
 */
library AccountExposure {
    using Account for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Market for Market.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;

    // todo: @avniculae @0xZenus think about why/whether we still need the 
    // token parameter here, since single account mode was removed. However,
    // parts of code (such as liquidations and withdrawable balance) currently
    // pass the collateralType in the token parameter. 
    function getMarginInfoByBubble(Account.Data storage account, address token) 
        internal 
        view
        returns (Account.MarginInfo memory) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;

        address quoteToken = address(0);
        Account.MarginInfo memory marginInfo = computeMarginInfoByBubble(
            account,
            collateralPoolId,
            address(0),
            collateralPool.riskConfig.riskMultipliers
        ); 

        if (token == quoteToken) {
            return marginInfo;
        }

        // Direct exchange rate
        CollateralConfiguration.ExchangeInfo memory exchange = 
            CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteToken, token);

        // todo: note, in here we divide by the exchange rate that also has the haircut applied to it
        // to make sure the deltas are in the units of the base token
        // however, the haircut is originally only applied if the delta is positive, that same logic
        // doesn't seem to be present here, is that intentional?
        return Account.MarginInfo({
            collateralType: token,
            collateralInfo: Account.CollateralInfo({
                netDeposits: getExchangedQuantity(marginInfo.collateralInfo.netDeposits, exchange.price, exchange.priceHaircut),
                marginBalance: getExchangedQuantity(marginInfo.collateralInfo.marginBalance, exchange.price, exchange.priceHaircut),
                realBalance: getExchangedQuantity(marginInfo.collateralInfo.realBalance, exchange.price, exchange.priceHaircut)
            }),
            initialDelta: getExchangedQuantity(marginInfo.initialDelta, exchange.price, exchange.priceHaircut),
            maintenanceDelta: getExchangedQuantity(marginInfo.maintenanceDelta, exchange.price, exchange.priceHaircut),
            liquidationDelta: getExchangedQuantity(marginInfo.liquidationDelta, exchange.price, exchange.priceHaircut),
            dutchDelta: getExchangedQuantity(marginInfo.dutchDelta, exchange.price, exchange.priceHaircut),
            adlDelta: getExchangedQuantity(marginInfo.adlDelta, exchange.price, exchange.priceHaircut),
            dutchHealthInfo: Account.DutchHealthInformation({
                rawMarginBalance: 
                    getExchangedQuantity(marginInfo.dutchHealthInfo.rawMarginBalance, exchange.priceHaircut, ZERO),
                rawLiquidationMarginRequirement:
                    getExchangedQuantity(
                        marginInfo.dutchHealthInfo.rawLiquidationMarginRequirement.toInt(), 
                        exchange.priceHaircut, 
                        ZERO
                    ).toUint()
            })
        });
    }

    function computeMarginInfoByBubble(
        Account.Data storage account, 
        uint128 collateralPoolId, 
        address quoteToken, 
        CollateralPool.RiskMultipliers memory riskMultipliers
    ) 
        private 
        view
        returns(Account.MarginInfo memory marginInfo) 
    {
        marginInfo = getMarginInfoByCollateralType(
            account,
            quoteToken,
            riskMultipliers
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
                    riskMultipliers
                );

            CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralPoolId, tokens[i]);
            UD60x18 price = collateral.getParentPrice();
            UD60x18 haircut = collateral.parentConfig.priceHaircut;

            marginInfo = Account.MarginInfo({
                collateralType: marginInfo.collateralType,
                collateralInfo: Account.CollateralInfo({
                    netDeposits: marginInfo.collateralInfo.netDeposits,
                    marginBalance:  marginInfo.collateralInfo.marginBalance +
                    getExchangedQuantity(subMarginInfo.collateralInfo.marginBalance, price, haircut),
                    realBalance:
                    marginInfo.collateralInfo.realBalance +
                    getExchangedQuantity(subMarginInfo.collateralInfo.realBalance, price, haircut)
                }),
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
                    getExchangedQuantity(subMarginInfo.adlDelta, price, haircut),
                dutchHealthInfo: Account.DutchHealthInformation({
                    rawMarginBalance: 
                        marginInfo.dutchHealthInfo.rawMarginBalance + 
                        getExchangedQuantity(subMarginInfo.dutchHealthInfo.rawMarginBalance, price, ZERO),
                    rawLiquidationMarginRequirement: 
                        marginInfo.dutchHealthInfo.rawLiquidationMarginRequirement +
                        getExchangedQuantity(
                            subMarginInfo.dutchHealthInfo.rawLiquidationMarginRequirement.toInt(), 
                            price, 
                            ZERO
                        ).toUint()
                })  
            });
        }
    }

    struct MarginInfoVars {
        int256 realizedPnL;
        int256 unrealizedPnL;
        uint256 liquidationMarginRequirement;
        uint256 initialMarginRequirement;
        uint256 maintenanceMarginRequirement;
        uint256 dutchMarginRequirement;
        uint256 adlMarginRequirement;
    }

    function getAllExposures(
        Account.Data storage self,
        uint256[] memory markets
    ) private view returns (Account.MarketExposure[] memory allExposures) {

        uint256 exposuresCounter;

        for (uint256 i = 0; i < markets.length; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            Account.MarketExposure[] memory marketExposures = market.getAccountTakerAndMakerExposures(self.id);

            for (uint256 j = 0; j < marketExposures.length; j++) {

                allExposures[exposuresCounter] = marketExposures[j];
                exposuresCounter += 1;

            }

        }

        return allExposures;

    }

    function getAggregatePnLComponents(
        Account.MarketExposure[] memory exposures
    ) private view returns (int256 realizedPnL, int256 unrealizedPnL) {

        for (uint256 i = 0; i < exposures.length; i++) {

            realizedPnL += exposures[i].pnlComponents.realizedPnL;
            unrealizedPnL += exposures[i].pnlComponents.unrealizedPnL;

        }

        return (realizedPnL, unrealizedPnL);

    }

    /**
     * @dev Returns the margin info for a given account
     * @dev The amounts are in collateral type. 
     */
    function getMarginInfoByCollateralType(
        Account.Data storage self, 
        address collateralType,
        CollateralPool.RiskMultipliers memory riskMultipliers
    )
        internal
        view
        returns (Account.MarginInfo memory marginInfo)
    {
        MarginInfoVars memory vars;

        uint256[] memory markets = self.activeMarketsPerQuoteToken[collateralType].values();

        (Account.MarketExposure[] memory allExposures) = getAllExposures(self, markets);
        (vars.realizedPnL, vars.unrealizedPnL) = getAggregatePnLComponents(allExposures);

        vars.liquidationMarginRequirement = computeLiquidationMarginRequirement(
            self.getCollateralPool(),
            allExposures
        );
        vars.initialMarginRequirement = mulUDxUint(riskMultipliers.imMultiplier, vars.liquidationMarginRequirement);
        vars.maintenanceMarginRequirement  = mulUDxUint(riskMultipliers.mmrMultiplier, vars.liquidationMarginRequirement);
        vars.dutchMarginRequirement  = mulUDxUint(riskMultipliers.dutchMultiplier, vars.liquidationMarginRequirement);
        vars.adlMarginRequirement  = mulUDxUint(riskMultipliers.adlMultiplier, vars.liquidationMarginRequirement);
        int256 netDeposits = self.getAccountNetCollateralDeposits(collateralType);
        int256 marginBalance = netDeposits + vars.realizedPnL + vars.unrealizedPnL;
        int256 realBalance = netDeposits + vars.realizedPnL;

        return Account.MarginInfo({
            collateralType: collateralType,
            collateralInfo: Account.CollateralInfo({
                netDeposits: netDeposits,
                marginBalance: marginBalance,
                realBalance: realBalance
            }),
            initialDelta: marginBalance - vars.initialMarginRequirement.toInt(),
            maintenanceDelta: marginBalance - vars.maintenanceMarginRequirement.toInt(),
            liquidationDelta: marginBalance - vars.liquidationMarginRequirement.toInt(),
            dutchDelta: marginBalance - vars.dutchMarginRequirement.toInt(),
            adlDelta: marginBalance - vars.adlMarginRequirement.toInt(),
            dutchHealthInfo: Account.DutchHealthInformation({
                rawMarginBalance: marginBalance,
                rawLiquidationMarginRequirement: vars.liquidationMarginRequirement
            })
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


    function getRiskParameter(
        CollateralPool.Data storage collateralPool,
        Account.MarketExposure memory exposureA,
        Account.MarketExposure memory exposureB
    ) private view returns (SD59x18 riskParameter) {

        if (exposureA.riskBlockId == exposureB.riskBlockId) {
            riskParameter = collateralPool.riskMatrix[exposureA.riskBlockId][exposureA.riskMatrixRowId]
                [exposureB.riskMatrixRowId];
        }

        return riskParameter;
    }


    function getExposure(
        Account.MarketExposure memory exposure,
        uint256 exposureIndex,
        int256 unfilledIndex,
        bool isLong
    ) private view returns (int256) {

        if ((unfilledIndex > 0) && (exposureIndex == unfilledIndex.toUint())) {
            return isLong ? exposure.exposureComponents.cfExposureLong : exposure.exposureComponents.cfExposureShort;
        }

        return exposure.exposureComponents.filledExposure;
    }

    function computeLMRFilled(
        CollateralPool.Data storage collateralPool,
        Account.MarketExposure[] memory exposures,
        int256 unfilledIndex,
        bool isLong
    ) private view returns (uint256) {

        SD59x18 lmrFilledSquared;

        for (uint256 i = 0; i < exposures.length; i++) {

            int256 exposureA = getExposure(exposures[i], i, unfilledIndex, isLong);

            for (uint256 j = 0; i < exposures.length; j++) {

                int256 exposureB = getExposure(exposures[j], j, unfilledIndex, isLong);

                SD59x18 riskParam = getRiskParameter(
                    collateralPool,
                    exposures[i],
                    exposures[j]
                );

                if (unwrap(riskParam) != 0) {
                    lmrFilledSquared.add(sd(exposureA).mul(sd(exposureB)).mul(riskParam));
                }

            }

        }

        return lmrFilledSquared.sqrt().unwrap().toUint();
    }

    function hasUnfilledExposure(
        Account.MarketExposure memory exposure,
        bool isLong
    ) private view returns (bool hasUnfilled) {

        if (isLong) {
            hasUnfilled = exposure.exposureComponents.cfExposureLong != exposure.exposureComponents.filledExposure;
        } else {
            hasUnfilled = exposure.exposureComponents.cfExposureShort != exposure.exposureComponents.filledExposure;
        }

        return hasUnfilled;
    }

    function computeLMRUnfilled(
        CollateralPool.Data storage collateralPool,
        Account.MarketExposure[] memory exposures,
        uint256 lmrFilled
    ) private view returns (uint256 lmrUnfilled) {

        for (uint256 i = 0; i < exposures.length; i++) {

            uint256 lmrLong;
            uint256 lmrShort;

            if (hasUnfilledExposure(exposures[i], true)) {
                uint256 lmrLongCF = computeLMRFilled(collateralPool, exposures, i.toInt(), true);
                lmrLong = lmrLongCF > lmrFilled ? lmrLongCF - lmrFilled : 0;
                lmrLong += exposures[i].pvmrComponents.pvmrLong;
            }

            if (hasUnfilledExposure(exposures[i], false)) {
                uint256 lmShortCF = computeLMRFilled(collateralPool, exposures, i.toInt(), false);
                lmrShort = lmShortCF > lmrFilled ? lmShortCF - lmrFilled : 0;
                lmrShort += exposures[i].pvmrComponents.pvmrShort;
            }

            lmrUnfilled += lmrLong > lmrShort ? lmrLong : lmrShort;

        }

        return lmrUnfilled;
    }

    /**
     * @dev Returns the liquidation margin requirement given the exposures array
     */
    function computeLiquidationMarginRequirement(
        CollateralPool.Data storage collateralPool,
        Account.MarketExposure[] memory exposures
    )
    private
    view
    returns (uint256 liquidationMarginRequirement)
    {
        uint256 lmrFilled = computeLMRFilled(collateralPool, exposures, -1, false);
        uint256 lmrUnfilled = computeLMRUnfilled(collateralPool, exposures, lmrFilled);
        liquidationMarginRequirement = lmrFilled + lmrUnfilled;
        return liquidationMarginRequirement;
    }


}
