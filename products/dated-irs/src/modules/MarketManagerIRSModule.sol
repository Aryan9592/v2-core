/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {IMarketManagerIRSModule} from "../interfaces/IMarketManagerIRSModule.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Portfolio} from "../storage/Portfolio.sol";
import {Market} from "../storage/Market.sol";
import {MarketManagerConfiguration} from "../storage/MarketManagerConfiguration.sol";
import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";

import {IAccountModule} from "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IMarketManagerModule} from "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";

import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import {SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {IERC165} from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Dated Interest Rate Swap Market Manager
 * @dev See IMarketManagerIRSModule
 */

contract MarketManagerIRSModule is IMarketManagerIRSModule {
    using Market for Market.Data;
    using Portfolio for Portfolio.Data;
    using SafeCastI256 for int256;

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function initiateTakerOrder(TakerOrderParams memory params)
        external
        override
        returns (int256 executedBaseAmount, int256 executedQuoteAmount, uint256 fee, Account.MarginRequirement memory mr)
    {
        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        // check account access permissions
        IAccountModule(coreProxy).onlyAuthorized(params.accountId, Account.ADMIN_PERMISSION, msg.sender);

        Market.Data storage market = Market.exists(params.marketId);
        IPool pool = IPool(market.marketConfig.poolAddress);

        // todo: check with @ab if we want it adjusted or not
        UD60x18 markPrice = pool.getAdjustedDatedIRSTwap(
            params.marketId, 
            params.maturityTimestamp, 
            params.baseAmount, 
            market.marketConfig.twapLookbackWindow
        );

        // todo: check there is an active pool with maturityTimestamp requested
        (executedBaseAmount, executedQuoteAmount) =
            pool.executeDatedTakerOrder(
                params.marketId, 
                params.maturityTimestamp, 
                params.baseAmount, 
                params.priceLimit, 
                markPrice, 
                market.marketConfig.markPriceBand
            );

        Portfolio.loadOrCreate(params.accountId, params.marketId).updatePosition(
            params.maturityTimestamp, executedBaseAmount, executedQuoteAmount
        );

        // propagate order
        int256 annualizedNotionalAmount = getSingleAnnualizedExposure(
            executedBaseAmount, params.marketId, params.maturityTimestamp
        );
        
        (fee, mr) = IMarketManagerModule(coreProxy).propagateTakerOrder(
            params.accountId,
            params.marketId,
            market.quoteToken,
            annualizedNotionalAmount
        );

        market.updateOracleStateIfNeeded();

        emit TakerOrder(
            params.accountId,
            params.marketId,
            params.maturityTimestamp,
            market.quoteToken,
            executedBaseAmount,
            executedQuoteAmount,
            annualizedNotionalAmount,
            block.timestamp
        );
    }

    function getSingleAnnualizedExposure(
        int256 executedBaseAmount,
        uint128 marketId,
        uint32 maturityTimestamp
    ) internal view returns (int256 annualizedNotionalAmount) {
        int256[] memory baseAmounts = new int256[](1);
        baseAmounts[0] = executedBaseAmount;
        annualizedNotionalAmount = baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp)[0];
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    // note: return settlementCashflowInQuote?
    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) external override {
        Market.Data storage market = Market.exists(marketId);
        market.updateRateIndexAtMaturityCache(maturityTimestamp);

        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        // check account access permissions
        IAccountModule(coreProxy).onlyAuthorized(accountId, Account.ADMIN_PERMISSION, msg.sender);

        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        int256 settlementCashflowInQuote = portfolio.settle(marketId, maturityTimestamp, market.marketConfig.poolAddress);

        address quoteToken = market.quoteToken;

        IMarketManagerModule(coreProxy).propagateCashflow(accountId, marketId, quoteToken, settlementCashflowInQuote);

        emit DatedIRSPositionSettled(
            accountId, marketId, maturityTimestamp, quoteToken, settlementCashflowInQuote, block.timestamp
        );
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function name() external pure override returns (string memory) {
        return "Dated IRS Market Manager";
    }

    function baseToAnnualizedExposure(
        int256[] memory baseAmounts,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        public
        view
        returns (int256[] memory exposures)
    {
        exposures = new int256[](baseAmounts.length);
        exposures = ExposureHelpers.baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp);
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function getAccountTakerAndMakerExposures(
        uint128 accountId,
        uint128 marketId
    )
        external
        view
        override
        returns (Account.MakerMarketExposure[] memory exposures)
    {
        return Portfolio.exists(accountId, marketId).getAccountTakerAndMakerExposures();
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function closeAccount(uint128 accountId, uint128 marketId) external override {
        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();

        if (
            !IAccountModule(coreProxy).isAuthorized(accountId, Account.ADMIN_PERMISSION, msg.sender)
                && msg.sender != MarketManagerConfiguration.getCoreProxyAddress()
        ) {
            revert NotAuthorized(msg.sender, "closeAccount");
        }

        Portfolio.exists(accountId, marketId).closeAccount();
    }

    function configureMarketManager(MarketManagerConfiguration.Data memory config) external {
        OwnableStorage.onlyOwner();

        MarketManagerConfiguration.set(config);
        emit MarketManagerConfigured(config, block.timestamp);
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function getCoreProxyAddress() external view returns (address) {
        return MarketManagerConfiguration.getCoreProxyAddress();
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function propagateMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount
    ) external returns (uint256 fee, Account.MarginRequirement memory mr) {
        Market.Data storage market = Market.exists(marketId);
        if (msg.sender != market.marketConfig.poolAddress) {
            revert NotAuthorized(msg.sender, "propagateMakerOrder");
        }

        Portfolio.loadOrCreate(accountId, marketId).updatePosition(maturityTimestamp, 0, 0);

        int256 annualizedNotionalAmount = getSingleAnnualizedExposure(baseAmount, marketId, maturityTimestamp);

        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();
        (fee, mr) = IMarketManagerModule(coreProxy).propagateMakerOrder(
            accountId,
            marketId,
            market.quoteToken,
            annualizedNotionalAmount
        );

        market.updateOracleStateIfNeeded();
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return interfaceId == type(IMarketManagerIRSModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
