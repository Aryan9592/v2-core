/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { 
    MarginInfo, 
    PnLComponents, 
    UnfilledExposure, 
    UnfilledExposureComponents, 
    CollateralInfo,
    RawInformation
} from "../../libraries/DataTypes.sol";
import {Account} from "../../storage/Account.sol";
import {CollateralConfiguration} from "../../storage/CollateralConfiguration.sol";
import {CollateralPool} from "../../storage/CollateralPool.sol";
import {Market} from "../../storage/Market.sol";

import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {mulUDxUint, mulUDxInt, UD60x18} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { sd, unwrap, SD59x18 } from "@prb/math/SD59x18.sol";
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
        returns (MarginInfo memory) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;

        address quoteToken = address(0);
        MarginInfo memory marginInfo = computeMarginInfoByBubble(
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
        return MarginInfo({
            collateralType: token,
            collateralInfo: CollateralInfo({
                netDeposits: getExchangedQuantity(marginInfo.collateralInfo.netDeposits, exchange.price, exchange.priceHaircut),
                marginBalance: getExchangedQuantity(marginInfo.collateralInfo.marginBalance, exchange.price, exchange.priceHaircut),
                realBalance: getExchangedQuantity(marginInfo.collateralInfo.realBalance, exchange.price, exchange.priceHaircut)
            }),
            initialDelta: getExchangedQuantity(marginInfo.initialDelta, exchange.price, exchange.priceHaircut),
            maintenanceDelta: getExchangedQuantity(marginInfo.maintenanceDelta, exchange.price, exchange.priceHaircut),
            liquidationDelta: getExchangedQuantity(marginInfo.liquidationDelta, exchange.price, exchange.priceHaircut),
            dutchDelta: getExchangedQuantity(marginInfo.dutchDelta, exchange.price, exchange.priceHaircut),
            adlDelta: getExchangedQuantity(marginInfo.adlDelta, exchange.price, exchange.priceHaircut),
            initialBufferDelta: getExchangedQuantity(marginInfo.initialBufferDelta, exchange.price, exchange.priceHaircut),
            rawInfo: RawInformation({
                rawMarginBalance: 
                    getExchangedQuantity(marginInfo.rawInfo.rawMarginBalance, exchange.priceHaircut, ZERO),
                rawLiquidationMarginRequirement:
                    getExchangedQuantity(
                        marginInfo.rawInfo.rawLiquidationMarginRequirement.toInt(), 
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
        returns(MarginInfo memory marginInfo) 
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
            MarginInfo memory subMarginInfo  = 
                computeMarginInfoByBubble(
                    account,
                    collateralPoolId,
                    tokens[i],
                    riskMultipliers
                );

            CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralPoolId, tokens[i]);
            UD60x18 price = collateral.getParentPrice();
            UD60x18 haircut = collateral.parentConfig.priceHaircut;

            marginInfo = MarginInfo({
                collateralType: marginInfo.collateralType,
                collateralInfo: CollateralInfo({
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
                initialBufferDelta:
                    marginInfo.initialBufferDelta + 
                    getExchangedQuantity(subMarginInfo.initialBufferDelta, price, haircut),
                rawInfo: RawInformation({
                    rawMarginBalance: 
                        marginInfo.rawInfo.rawMarginBalance + 
                        getExchangedQuantity(subMarginInfo.rawInfo.rawMarginBalance, price, ZERO),
                    rawLiquidationMarginRequirement: 
                        marginInfo.rawInfo.rawLiquidationMarginRequirement +
                        getExchangedQuantity(
                            subMarginInfo.rawInfo.rawLiquidationMarginRequirement.toInt(), 
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
        uint256 initialBufferMarginRequirement;
    }

    function getBlockExposures(
        Account.Data storage self,
        uint256 riskBlockId,
        uint256 riskMatrixDim,
        uint256[] memory markets
    ) private view returns (
        int256[] memory filledExposures,
        UnfilledExposure[] memory unfilledExposures
    ) {

        filledExposures = new int256[](riskMatrixDim);
        uint256 unfilledExposuresCounter;

        for (uint256 i = 0; i < markets.length; i++) {

            Market.Data storage market = Market.exists(markets[i].to128());

            if (!(market.riskBlockId == riskBlockId)) {
                continue;
            }

            int256[] memory marketFilledExposures = market.getAccountTakerExposures(self.id, riskMatrixDim);

            UnfilledExposure[] memory marketUnfilledExposures = market.getAccountMakerExposures(self.id);

            // todo: revert if marketFilledExposures.length doesn't match the riskMatrixDim

            for (uint256 j = 0; j < marketFilledExposures.length; j++) {
                filledExposures[j] += marketFilledExposures[j];
            }

            for (uint256 k = 0; k < marketUnfilledExposures.length; k++) {

                unfilledExposures[unfilledExposuresCounter] = marketUnfilledExposures[k];
                unfilledExposuresCounter += 1;

            }

        }

        return (filledExposures, unfilledExposures);

    }

    function getAggregatePnLComponents(
        Account.Data storage self,
        uint256[] memory markets
    ) private view returns (int256 realizedPnL, int256 unrealizedPnL) {

        for (uint256 i = 0; i < markets.length; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            PnLComponents memory pnlComponents = market.getAccountPnLComponents(self.id);

            realizedPnL += pnlComponents.realizedPnL;
            unrealizedPnL += pnlComponents.unrealizedPnL;
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
        returns (MarginInfo memory marginInfo)
    {
        MarginInfoVars memory vars;

        uint256[] memory markets = self.activeMarketsPerQuoteToken[collateralType].values();

        CollateralPool.Data storage collateralPool = self.getCollateralPool();

        for (uint256 i = 0; i < collateralPool.riskBlockCount; i++) {

            uint256 riskMatrixDim = collateralPool.riskMatrixDims[i];

            (
                int256[] memory filledExposures,
                UnfilledExposure[] memory unfilledExposures
            ) = getBlockExposures(self, i, riskMatrixDim, markets);

            vars.liquidationMarginRequirement += computeLiquidationMarginRequirement(
                collateralPool,
                i,
                filledExposures,
                unfilledExposures
            );

        }

        (vars.realizedPnL, vars.unrealizedPnL) = getAggregatePnLComponents(self, markets);

        // Get the maintenance margin requirement
        vars.maintenanceMarginRequirement = mulUDxUint(riskMultipliers.mmrMultiplier, vars.liquidationMarginRequirement);

        // Get the dutch margin requirement
        vars.dutchMarginRequirement = mulUDxUint(riskMultipliers.dutchMultiplier, vars.liquidationMarginRequirement);

        // Get the adl margin requirement
        vars.adlMarginRequirement = mulUDxUint(riskMultipliers.adlMultiplier, vars.liquidationMarginRequirement);

        // Get the initial buffer margin requirement
        vars.initialBufferMarginRequirement = mulUDxUint(riskMultipliers.imBufferMultiplier, vars.liquidationMarginRequirement);

        // Get the collateral balance of the account in this specific collateral
        int256 netDeposits = self.getAccountNetCollateralDeposits(collateralType);
        int256 marginBalance = netDeposits + vars.realizedPnL + vars.unrealizedPnL;
        int256 realBalance = netDeposits + vars.realizedPnL;

        return MarginInfo({
            collateralType: collateralType,
            collateralInfo: CollateralInfo({
                netDeposits: netDeposits,
                marginBalance: marginBalance,
                realBalance: realBalance
            }),
            initialDelta: marginBalance - vars.initialMarginRequirement.toInt(),
            maintenanceDelta: marginBalance - vars.maintenanceMarginRequirement.toInt(),
            liquidationDelta: marginBalance - vars.liquidationMarginRequirement.toInt(),
            dutchDelta: marginBalance - vars.dutchMarginRequirement.toInt(),
            adlDelta: marginBalance - vars.adlMarginRequirement.toInt(),
            initialBufferDelta: marginBalance - vars.initialBufferMarginRequirement.toInt(),
            rawInfo: RawInformation({
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


    function computeLMRFilled(
        CollateralPool.Data storage collateralPool,
        uint256 riskBlockId,
        int256[] memory exposures
    ) private view returns (uint256) {

        SD59x18 lmrFilledSquared;

        for (uint256 i = 0; i < exposures.length; i++) {

            for (uint256 j = 0; i < exposures.length; j++) {

                SD59x18 riskParam = collateralPool.riskMatrix[riskBlockId][i][j];

                if (unwrap(riskParam) != 0) {
                    lmrFilledSquared.add(sd(exposures[i]).mul(sd(exposures[j])).mul(riskParam));
                }

            }

        }

        return lmrFilledSquared.sqrt().unwrap().toUint();
    }



    function hasUnfilledExposure(
        UnfilledExposureComponents memory unfilledExposureComponents,
        bool isLong
    ) private pure returns (bool) {
        int256[] memory target = (isLong) ? unfilledExposureComponents.long : unfilledExposureComponents.short;

        for (uint256 i = 0; i < target.length; i++) {
            if (target[i] != 0) {
                return true;
            }
        }

        return false;
    }

    function getCFExposures(
        uint256[] memory riskMatrixRowIds,
        UnfilledExposureComponents memory unfilledExposureComponents,
        int256[] memory filledExposures,
        bool isLong
    ) private pure returns (int256[] memory) {
        int256[] memory target = (isLong) ? unfilledExposureComponents.long : unfilledExposureComponents.short;

        for (uint256 i = 0; i < riskMatrixRowIds.length; i++) {
            filledExposures[i] += target[i];
        }

        return filledExposures;

    }

    function computeLMRUnfilled(
        CollateralPool.Data storage collateralPool,
        uint256 riskBlockId,
        int256[] memory filledExposures,
        UnfilledExposure[] memory unfilledExposures,
        uint256 lmrFilled
    ) private view returns (uint256 lmrUnfilled) {

        for (uint256 i = 0; i < unfilledExposures.length; i++) {

            uint256 lmrLong;
            uint256 lmrShort;

            UnfilledExposure memory unfilledExposure = unfilledExposures[i];

            if (hasUnfilledExposure(unfilledExposure.exposureComponents, true)) {

                int256[] memory cfExposuresLong = getCFExposures(
                    unfilledExposure.riskMatrixRowIds,
                    unfilledExposure.exposureComponents,
                    filledExposures,
                    true
                );

                uint256 lmrLongCf = computeLMRFilled(collateralPool, riskBlockId, cfExposuresLong);

                lmrLong = lmrLongCf > lmrFilled ? lmrLongCf - lmrFilled : 0;
                lmrLong += unfilledExposure.pvmrComponents.long;

            }

            if (hasUnfilledExposure(unfilledExposure.exposureComponents, false)) {

                int256[] memory cfExposuresShort = getCFExposures(
                    unfilledExposure.riskMatrixRowIds,
                    unfilledExposure.exposureComponents,
                    filledExposures,
                    false
                );

                uint256 lmrShortCf = computeLMRFilled(collateralPool, riskBlockId, cfExposuresShort);

                lmrShort = lmrShortCf > lmrFilled ? lmrShortCf - lmrFilled : 0;
                lmrShort += unfilledExposure.pvmrComponents.short;

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
        uint256 riskBlockId,
        int256[] memory filledExposures,
        UnfilledExposure[] memory unfilledExposures
    )
    private
    view
    returns (uint256 liquidationMarginRequirement)
    {
        uint256 lmrFilled = computeLMRFilled(collateralPool, riskBlockId, filledExposures);
        uint256 lmrUnfilled = computeLMRUnfilled(collateralPool, riskBlockId, filledExposures, unfilledExposures, lmrFilled);
        liquidationMarginRequirement = lmrFilled + lmrUnfilled;
        return liquidationMarginRequirement;
    }


}
