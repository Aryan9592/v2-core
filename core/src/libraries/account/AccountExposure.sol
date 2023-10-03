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
import {mulUDxUint, mulUDxInt, UD60x18} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
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
        uint256 liquidationMarginRequirement;

        int256 accruedCashflows;
        int256 lockedPnL;
        int256 highestUnrealizedLoss;

        uint256 initialMarginRequirement;
        uint256 maintenanceMarginRequirement;
        uint256 dutchMarginRequirement;
        uint256 adlMarginRequirement;
    }

    function getExposuresCount(
        Account.Data storage self,
        uint256[] memory markets
    ) private view returns (uint256 exposuresCount) {

        for (uint256 i = 0; i < markets.length; i++) {

            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);
            Account.MarketExposure[] memory marketExposures = market.getAccountTakerAndMakerExposures(self.id);
            exposuresCount += marketExposures.length;

        }

        return exposuresCount;
    }

    function getAllExposures(
        Account.Data storage self,
        uint256[] memory markets,
        uint256 exposuresCount
    )  private view returns (Account.MarketExposure[] memory) {

        Account.MarketExposure[] memory allExposures = new Account.MarketExposure[](exposuresCount);
        uint256 exposuresCounter;

        for (uint256 i = 0; i < markets.length; i++) {
            uint128 marketId = markets[i].to128();
            Market.Data storage market = Market.exists(marketId);

            Account.MarketExposure[] memory marketExposures = market.getAccountTakerAndMakerExposures(self.id);

            for (uint256 j = 0; j < marketExposures.length; j++) {

                allExposures[exposuresCounter] = marketExposures[j];

            }

        }

        return allExposures;

    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirement deltas
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

        uint256 exposuresCount = getExposuresCount(self, markets);
        Account.MarketExposure[] memory allExposures = getAllExposures(self, markets, exposuresCount);
        vars.liquidationMarginRequirement = computeLiquidationMarginRequirement(allExposures);

        // Get the initial margin requirement
        vars.initialMarginRequirement = mulUDxUint(riskMultipliers.imMultiplier, vars.liquidationMarginRequirement);

        // Get the maintenance margin requirement
        vars.maintenanceMarginRequirement  = mulUDxUint(riskMultipliers.mmrMultiplier, vars.liquidationMarginRequirement);

        // Get the dutch margin requirement
        vars.dutchMarginRequirement  = mulUDxUint(riskMultipliers.dutchMultiplier, vars.liquidationMarginRequirement);

        // Get the adl margin requirement
        vars.adlMarginRequirement  = mulUDxUint(riskMultipliers.adlMultiplier, vars.liquidationMarginRequirement);

        // Get the collateral balance of the account in this specific collateral
        int256 netDeposits = self.getAccountNetCollateralDeposits(collateralType);

        // todo: margin balance should have the unrealized pnl from filled orders!
        // otherwise we're being too restrictive
        int256 marginBalance = netDeposits + vars.accruedCashflows + vars.lockedPnL + vars.highestUnrealizedLoss;
        int256 realBalance = netDeposits + vars.accruedCashflows + vars.lockedPnL;
        
        // todo: make sure when we're adding the highestUnrealizedLoss it's only from unfilled orders
        // filled orders should be taken care of in the balance calculations
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

    /**
     * @dev Returns the liquidation margin requirement given the exposures array
     */
    function computeLiquidationMarginRequirement(Account.MarketExposure[] memory)
    private
    view
    returns (uint256 liquidationMarginRequirement)
    {
        return liquidationMarginRequirement;
    }


}
