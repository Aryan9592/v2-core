/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {CollateralPool} from "../storage/CollateralPool.sol";
import {Market} from "../storage/Market.sol";
import {MarketStore} from "../storage/MarketStore.sol";
import {IMarketManager} from "../interfaces/external/IMarketManager.sol";
import {IMarketManagerModule} from "../interfaces/IMarketManagerModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import {ERC165Helper} from "@voltz-protocol/util-contracts/src/helpers/ERC165Helper.sol";
import {SignedMath} from "oz/utils/math/SignedMath.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Protocol-wide entry point for the management of markets connected to the protocol.
 * @dev See IMarketManagerModule
 */
contract MarketManagerModule is IMarketManagerModule {
    using Account for Account.Data;
    using Market for Market.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.UintSet;

    function getLastCreatedMarketId() external view override returns (uint128) {
        return MarketStore.getMarketStore().lastCreatedMarketId;
    }

    /**
     * @inheritdoc IMarketManagerModule
     */
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId)
        external
        override
        view
        returns (Account.MakerMarketExposure[] memory exposures)
    {
        exposures = Market.exists(marketId).getAccountTakerAndMakerExposures(accountId);
    }

    /**
     * @inheritdoc IMarketManagerModule
     */
    function registerMarket(address marketManager, string memory name) external override returns (uint128 marketId) {
        if (!ERC165Helper.safeSupportsInterface(marketManager, type(IMarketManager).interfaceId)) {
            revert IncorrectMarketInterface(marketManager);
        }

        marketId = Market.create(marketManager, name, msg.sender).id;

        emit MarketRegistered(marketManager, marketId, name, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc IMarketManagerModule
     */

    function closeAccount(uint128 marketId, uint128 accountId) external override {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account = Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);

        account.ensureEnabledCollateralPool();

        Market.exists(marketId).closeAccount(accountId);
        emit AccountClosed(accountId, marketId, msg.sender, block.timestamp);
    }

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
    ) internal returns (uint256 fee, Account.MarginRequirement memory mr) {
        Account.Data storage account = Account.exists(accountId);

        account.ensureEnabledCollateralPool();

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

        account.markActiveMarket(collateralType, market.id);

        mr = account.imCheck(collateralType);
        fee = protocolFeeAmount + collateralPoolFeeAmount + insuranceFundFeeAmount;
    }


    function propagateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, Account.MarginRequirement memory mr) {
        FeatureFlagSupport.ensureGlobalAccess();
        Market.onlyMarketAddress(marketId, msg.sender);

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

    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, Account.MarginRequirement memory mr) {
        FeatureFlagSupport.ensureGlobalAccess();
        Market.onlyMarketAddress(marketId, msg.sender);

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

    function propagateCashflow(uint128 accountId, uint128 marketId, address collateralType, int256 amount)
        external
        override
    {
        Account.Data storage account = Account.exists(accountId);

        FeatureFlagSupport.ensureGlobalAccess();
        Market.onlyMarketAddress(marketId, msg.sender);
        account.ensureEnabledCollateralPool();

        if (amount > 0) {
            account.increaseCollateralBalance(collateralType, amount.toUint());
        } else {
            account.decreaseCollateralBalance(collateralType, (-amount).toUint());
        }

    }
}
