/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/external/IProduct.sol";
import "../interfaces/IProductModule.sol";
import "../storage/Product.sol";
import "../storage/ProductCreator.sol";
import "../storage/MarketFeeConfiguration.sol";
import "@voltz-protocol/util-modules/src/storage/AssociatedSystem.sol";
import "@voltz-protocol/util-contracts/src/helpers/ERC165Helper.sol";
import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "oz/utils/math/SignedMath.sol";

import {mulUDxUint} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Protocol-wide entry point for the management of products connected to the protocol.
 * @dev See IProductModule
 */
contract ProductModule is IProductModule {
    using Account for Account.Data;
    using Product for Product.Data;
    using MarketFeeConfiguration for MarketFeeConfiguration.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using AssociatedSystem for AssociatedSystem.Data;
    using Collateral for Collateral.Data;
    using SetUtil for SetUtil.UintSet;

    bytes32 private constant _REGISTER_PRODUCT_FEATURE_FLAG = "registerProduct";
    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    function getLastCreatedProductId() external view override returns (uint128) {
        return ProductCreator.getProductStore().lastCreatedProductId;
    }


    /**
     * @inheritdoc IProductModule
     */
    function getAccountTakerAndMakerExposures(uint128 productId, uint128 accountId, address collateralType)
        external
        override
        view
        returns (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        )
    {
        (takerExposures, makerExposuresLower, makerExposuresUpper) = 
            Product.load(productId).getAccountTakerAndMakerExposures(accountId, collateralType);
    }

    /**
     * @inheritdoc IProductModule
     */
    function registerProduct(address product, string memory name, bool isTrusted) external override returns (uint128 productId) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);

        if (isTrusted) {
            // todo: consider removing the below feature flag in favour of an ownerOnly check (AN)
            /// unless there's a good reason to use a feature flag
            FeatureFlag.ensureAccessToFeature(_REGISTER_PRODUCT_FEATURE_FLAG);
        }

        if (!ERC165Helper.safeSupportsInterface(product, type(IProduct).interfaceId)) {
            revert IncorrectProductInterface(product);
        }

        productId = ProductCreator.create(product, name, msg.sender, isTrusted).id;

        emit ProductRegistered(product, productId, name, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc IProductModule
     */

    function closeAccount(uint128 productId, uint128 accountId, address collateralType) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._ADMIN_PERMISSION, msg.sender);
        Product.load(productId).closeAccount(accountId, collateralType);
        emit AccountClosed(accountId, collateralType, msg.sender, block.timestamp);
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
        payingAccount.collaterals[collateralType].decreaseCollateralBalance(fee);
        emit Collateral.CollateralUpdate(payingAccountId, collateralType, -fee.toInt(), block.timestamp);

        Account.Data storage receivingAccount = Account.exists(receivingAccountId);
        receivingAccount.collaterals[collateralType].increaseCollateralBalance(fee);
        emit Collateral.CollateralUpdate(receivingAccountId, collateralType, fee.toInt(), block.timestamp);
    }

    function checkAccountCanEngageWithProduct(
        uint128 trustlessProductIdTrustedByAccount,
        uint128 productId,
        bool isProductTrusted
    ) internal pure returns (bool) {

        if (isProductTrusted && trustlessProductIdTrustedByAccount == type(uint128).max) {
            return true;
        }

        if (!isProductTrusted && trustlessProductIdTrustedByAccount == productId) {
            return true;
        }

        return false;
    }

    function propagateTakerOrder(
        uint128 accountId,
        uint128 productId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, uint256 im, uint256 highestUnrealizedLoss) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        // todo: consider checking if the product exists or is it implicitly done in .onlyProductAddress() call (AN)
        Product.onlyProductAddress(productId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        Product.Data storage product = Product.load(productId);

        bool accountCanEngageWithProduct = checkAccountCanEngageWithProduct(
            account.trustlessProductIdTrustedByAccount, product.id, product.isTrusted
        );

        if (!accountCanEngageWithProduct) {
            revert AccountCannotEngageWithProduct(account.id, product.id);
        }

        MarketFeeConfiguration.Data memory feeConfig = MarketFeeConfiguration.load(productId, marketId);
        fee = distributeFees(
            accountId, feeConfig.feeCollectorAccountId, feeConfig.atomicTakerFee, collateralType, annualizedNotional
        );


        if (!account.activeProducts.contains(productId)) {
            account.activeProducts.add(productId);
        }

        if (account.isMultiToken) {
            (im, highestUnrealizedLoss) = account.imCheckAllCollaterals();
        } else {
            (im, highestUnrealizedLoss) = account.imCheck(collateralType);
        }

    }

    function propagateMakerOrder(
        uint128 accountId,
        uint128 productId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, uint256 im, uint256 highestUnrealizedLoss) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Product.onlyProductAddress(productId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        Product.Data storage product = Product.load(productId);

        bool accountCanEngageWithProduct = checkAccountCanEngageWithProduct(
            account.trustlessProductIdTrustedByAccount, product.id, product.isTrusted
        );

        if (!accountCanEngageWithProduct) {
            revert AccountCannotEngageWithProduct(account.id, product.id);
        }

        if (annualizedNotional > 0) {
            MarketFeeConfiguration.Data memory feeConfig = MarketFeeConfiguration.load(productId, marketId);
            fee = distributeFees(
                accountId, feeConfig.feeCollectorAccountId, feeConfig.atomicMakerFee, collateralType, annualizedNotional
            );
        }

        if (!account.activeProducts.contains(productId)) {
            account.activeProducts.add(productId);
        }

        if (account.isMultiToken) {
            (im, highestUnrealizedLoss) = account.imCheckAllCollaterals();
        } else {
            (im, highestUnrealizedLoss) = account.imCheck(collateralType);
        }
    }

    function propagateSettlementCashflow(uint128 accountId, uint128 productId, address collateralType, int256 amount)
        external
        override
    {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Product.onlyProductAddress(productId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        if (amount > 0) {
            account.collaterals[collateralType].increaseCollateralBalance(amount.toUint());
            emit Collateral.CollateralUpdate(accountId, collateralType, amount, block.timestamp);
        } else {
            account.collaterals[collateralType].decreaseCollateralBalance((-amount).toUint());
            emit Collateral.CollateralUpdate(accountId, collateralType, amount, block.timestamp);
        }

    }
}
