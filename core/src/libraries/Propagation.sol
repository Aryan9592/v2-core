/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";
import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";
import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Library for propagation logic
 */
library Propagation {
    using Account for Account.Data;
    using SafeCastI256 for int256;
    using Market for Market.Data;

    function propagateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) internal returns (uint256 fee) {
        Market.Data memory market = Market.exists(marketId);
        return propagateOrder(
                accountId,
                market,
                collateralType,
                annualizedNotional,
                market.protocolFeeConfig.atomicTakerFee,
                market.collateralPoolFeeConfig.atomicTakerFee,
                market.insuranceFundFeeConfig.atomicTakerFee
        );
    }

    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) internal returns (uint256 fee) {
        Market.Data memory market = Market.exists(marketId);
        return propagateOrder(
                accountId,
                market,
                collateralType,
                annualizedNotional,
                market.protocolFeeConfig.atomicMakerFee,
                market.collateralPoolFeeConfig.atomicMakerFee,
                market.insuranceFundFeeConfig.atomicMakerFee
        );
    }

    function propagateCashflow(uint128 accountId, address collateralType, int256 amount)
        internal 
    {
        Account.Data storage account = Account.exists(accountId);

        if (amount > 0) {
            account.increaseCollateralBalance(collateralType, amount.toUint());
        } else {
            account.decreaseCollateralBalance(collateralType, (-amount).toUint());
        }

    }

    //////////////// HELPER FUNCTIONS ////////////////

    /**
     * @dev Internal function to distribute trade fees according to the market fee config
     * @param payingAccountId Account id of trade initiatior
     * @param receivingAccountId Account id of fee collector
     * @param atomicFee Fee percentage of annualized notional to be distributed
     * @param collateralType Quote token used to pay fees in
     * @param annualizedNotional Traded annualized notional
     */
    function distributeFees(
        uint128 payingAccountId,
        uint128 receivingAccountId,
        UD60x18 atomicFee,
        address collateralType,
        int256 annualizedNotional
    ) internal returns (uint256 fee) {
        fee = mulUDxUint(atomicFee, SignedMath.abs(annualizedNotional));

        Account.Data storage payingAccount = Account.exists(payingAccountId);
        payingAccount.decreaseCollateralBalance(collateralType, fee);

        Account.Data storage receivingAccount = Account.exists(receivingAccountId);
        receivingAccount.increaseCollateralBalance(collateralType, fee);
    }

    function propagateOrder(
        uint128 accountId,
        Market.Data memory market,
        address collateralType,
        int256 annualizedNotional,
        UD60x18 protocolFee, 
        UD60x18 collateralPoolFee, 
        UD60x18 insuranceFundFee
    ) internal returns (uint256 fee) {

        uint256 protocolFeeAmount = distributeFees(
            accountId, 
            market.protocolFeeCollectorAccountId, 
            protocolFee, 
            collateralType, 
            annualizedNotional
        );

        CollateralPool.Data storage collateralPool = 
            market.getCollateralPool();

        uint256 collateralPoolFeeAmount = distributeFees(
            accountId, 
            collateralPool.feeCollectorAccountId, 
            collateralPoolFee,
            collateralType, 
            annualizedNotional
        );

        uint256 insuranceFundFeeAmount = distributeFees(
            accountId, 
            collateralPool.insuranceFundConfig.accountId, 
            insuranceFundFee,
            collateralType, 
            annualizedNotional
        );

        fee = protocolFeeAmount + collateralPoolFeeAmount + insuranceFundFeeAmount;
    }
}