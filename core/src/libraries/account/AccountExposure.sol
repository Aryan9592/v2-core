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

    error UnsupportedAccountExposure(bytes32 accountMode);

    function getMarginInfoByBubble(Account.Data storage account, address token) 
        internal 
        view
        returns (Account.MarginInfo memory) 
    {
        CollateralPool.Data storage collateralPool = account.getCollateralPool();
        uint128 collateralPoolId = collateralPool.id;
        UD60x18 imMultiplier = collateralPool.riskConfig.imMultiplier;

        address quoteToken;
        if (account.accountMode == Account.SINGLE_TOKEN_MODE) {
            quoteToken = CollateralConfiguration.getQuoteToken(collateralPoolId, token);
        } else if (account.accountMode == Account.MULTI_TOKEN_MODE) {
            quoteToken = address(0);
        } else {
            revert UnsupportedAccountExposure(account.accountMode);
        }

        Account.MarginInfo memory marginInfo = computeMarginInfoByBubble(account, collateralPoolId, quoteToken, imMultiplier); 

        if (token == quoteToken) {
            return marginInfo;
        }

        // Direct exchange rate
        CollateralConfiguration.ExchangeInfo memory exchange = 
            CollateralConfiguration.getExchangeInfo(collateralPoolId, quoteToken, token);

        return Account.MarginInfo({
            collateralType: token,
            netDeposits: getExchangedQuantity(marginInfo.netDeposits, exchange.price, exchange.haircut),
            balances: Account.Balances({
                marginBalance: getExchangedQuantity(marginInfo.balances.marginBalance, exchange.price, exchange.haircut),
                realBalance: getExchangedQuantity(marginInfo.balances.realBalance, exchange.price, exchange.haircut)
            }),
            mrDeltas: Account.MarginRequirementDeltas({
                initialDelta: getExchangedQuantity(marginInfo.mrDeltas.initialDelta, exchange.price, exchange.haircut),
                liquidationDelta: getExchangedQuantity(marginInfo.mrDeltas.liquidationDelta, exchange.price, exchange.haircut)
            })
        });
    }

    function computeMarginInfoByBubble(
        Account.Data storage account, 
        uint128 collateralPoolId, 
        address quoteToken, 
        UD60x18 imMultiplier
    ) 
        private 
        view
        returns(Account.MarginInfo memory marginInfo) 
    {
        marginInfo = getMarginInfoByCollateralType(account, quoteToken, imMultiplier);

        address[] memory tokens = CollateralConfiguration.exists(collateralPoolId, quoteToken).childTokens.values();

        for (uint256 i = 0; i < tokens.length; i++) {
            Account.MarginInfo memory subMarginInfo  = 
                computeMarginInfoByBubble(account, collateralPoolId, tokens[i], imMultiplier);

            CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(collateralPoolId, tokens[i]);
            UD60x18 price = collateral.getParentPrice();
            UD60x18 haircut = collateral.parentConfig.exchangeHaircut;

            marginInfo = Account.MarginInfo({
                collateralType: marginInfo.collateralType,
                netDeposits: marginInfo.netDeposits,
                balances: Account.Balances({
                    marginBalance: 
                        marginInfo.balances.marginBalance + 
                        getExchangedQuantity(subMarginInfo.balances.marginBalance, price, haircut),
                    realBalance: 
                        marginInfo.balances.realBalance + 
                        getExchangedQuantity(subMarginInfo.balances.realBalance, price, haircut)
                }),
                mrDeltas: Account.MarginRequirementDeltas({
                    initialDelta: 
                        marginInfo.mrDeltas.initialDelta + 
                        getExchangedQuantity(subMarginInfo.mrDeltas.initialDelta, price, haircut),
                    liquidationDelta: 
                        marginInfo.mrDeltas.liquidationDelta + 
                        getExchangedQuantity(subMarginInfo.mrDeltas.liquidationDelta, price, haircut)
                })
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
        UD60x18 imMultiplier
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

        // Get the collateral balance of the account in this specific collateral
        int256 netDeposits = self.getAccountNetCollateralDeposits(collateralType);

        int256 marginBalance = netDeposits + accruedCashflows + lockedPnL + highestUnrealizedLoss;
        int256 realBalance = netDeposits + accruedCashflows + lockedPnL;

        uint256 initialMarginRequirement = computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);
        
        return Account.MarginInfo({
            collateralType: collateralType,
            netDeposits: netDeposits,
            balances: Account.Balances({
                marginBalance: marginBalance,
                realBalance: realBalance
            }),
            mrDeltas: Account.MarginRequirementDeltas({
                initialDelta: marginBalance - initialMarginRequirement.toInt(),
                liquidationDelta: marginBalance - liquidationMarginRequirement.toInt()
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

    /**
     * @dev Returns the initial margin requirement given the liquidation margin requirement and the im multiplier
     */
    function computeInitialMarginRequirement(uint256 liquidationMarginRequirement, UD60x18 imMultiplier)
    private
    pure
    returns (uint256 initialMarginRequirement)
    {
        initialMarginRequirement = mulUDxUint(imMultiplier, liquidationMarginRequirement);
    }
}
