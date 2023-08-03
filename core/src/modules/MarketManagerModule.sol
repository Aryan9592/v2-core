/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/external/IMarketManager.sol";
import "../interfaces/IMarketManagerModule.sol";
import "../storage/Market.sol";
import "../storage/MarketCreator.sol";
import "../storage/MarketFeeConfiguration.sol";
import "@voltz-protocol/util-modules/src/storage/AssociatedSystem.sol";
import "@voltz-protocol/util-contracts/src/helpers/ERC165Helper.sol";
import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";
import "oz/utils/math/SignedMath.sol";

import {mulUDxUint} from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Protocol-wide entry point for the management of markets connected to the protocol.
 * @dev See IMarketManagerModule
 */
contract MarketManagerModule is IMarketManagerModule {
    using Account for Account.Data;
    using Market for Market.Data;
    using MarketFeeConfiguration for MarketFeeConfiguration.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using AssociatedSystem for AssociatedSystem.Data;
    using SetUtil for SetUtil.UintSet;

    bytes32 private constant _REGISTER_MARKET_FEATURE_FLAG = "registerMarket";
    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    function getLastCreatedMarketId() external view override returns (uint128) {
        return MarketCreator.getMarketStore().lastCreatedMarketId;
    }

    /**
     * @inheritdoc IMarketManagerModule
     */
    function getAccountTakerAndMakerExposures(uint128 marketId, uint128 accountId)
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
            Market.load(marketId).getAccountTakerAndMakerExposures(accountId);
    }

    /**
     * @inheritdoc IMarketManagerModule
     */
    function registerMarket(address market, string memory name) external override returns (uint128 marketId) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);

        if (!ERC165Helper.safeSupportsInterface(market, type(IMarketManager).interfaceId)) {
            revert IncorrectMarketInterface(market);
        }

        marketId = MarketCreator.create(market, name, msg.sender).id;

        emit MarketRegistered(market, marketId, name, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc IMarketManagerModule
     */

    function closeAccount(uint128 marketId, uint128 accountId) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.loadAccountAndValidatePermission(accountId, AccountRBAC._ADMIN_PERMISSION, msg.sender);
        Market.load(marketId).closeAccount(accountId);
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

    function propagateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, uint256 im, uint256 highestUnrealizedLoss) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        // todo: consider checking if the market exists or is it implicitly done in .onlyMarketAddress() call (AN)
        Market.onlyMarketAddress(marketId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        Market.Data storage market = Market.load(marketId);

        // todo: check if account can engage with the market (i.e. if the market is in the collateral pool of the account)
        bool accountCanEngageWithMarket = true;

        if (!accountCanEngageWithMarket) {
            revert AccountCannotEngageWithMarket(account.id, market.id);
        }

        MarketFeeConfiguration.Data memory feeConfig = MarketFeeConfiguration.load(marketId);
        fee = distributeFees(
            accountId, feeConfig.feeCollectorAccountId, feeConfig.atomicTakerFee, collateralType, annualizedNotional
        );

        if (!account.activeMarketsPerQuoteToken[collateralType].contains(marketId)) {
            account.activeMarketsPerQuoteToken[collateralType].add(marketId);
        }

        (im, highestUnrealizedLoss) = account.imCheck(collateralType);
    }

    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        address collateralType,
        int256 annualizedNotional
    ) external override returns (uint256 fee, uint256 im, uint256 highestUnrealizedLoss) {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Market.onlyMarketAddress(marketId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        Market.Data storage market = Market.load(marketId);

        // todo: check if account can engage with the market (i.e. if the market is in the collateral pool of the account)
        bool accountCanEngageWithMarket = true;

        if (!accountCanEngageWithMarket) {
            revert AccountCannotEngageWithMarket(account.id, market.id);
        }

        if (annualizedNotional > 0) {
            MarketFeeConfiguration.Data memory feeConfig = MarketFeeConfiguration.load(marketId);
            fee = distributeFees(
                accountId, feeConfig.feeCollectorAccountId, feeConfig.atomicMakerFee, collateralType, annualizedNotional
            );
        }

        if (!account.activeMarketsPerQuoteToken[collateralType].contains(marketId)) {
            account.activeMarketsPerQuoteToken[collateralType].add(marketId);
        }

        account.imCheck(collateralType);
    }

    function propagateSettlementCashflow(uint128 accountId, uint128 marketId, address collateralType, int256 amount)
        external
        override
    {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Market.onlyMarketAddress(marketId, msg.sender);

        Account.Data storage account = Account.exists(accountId);
        if (amount > 0) {
            account.increaseCollateralBalance(collateralType, amount.toUint());
        } else {
            account.decreaseCollateralBalance(collateralType, (-amount).toUint());
        }

    }
}
