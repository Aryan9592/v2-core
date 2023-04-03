//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IProductIRSModule.sol";
import "../interfaces/IMarketConfigurationModule.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import "../storage/Portfolio.sol";
import "../storage/MarketConfiguration.sol";
import "../storage/ProductConfiguration.sol";
import "../storage/RateOracleReader.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/core/src/interfaces/IProductModule.sol";

/**
 * @title Dated Interest Rate Swap Product
 * @dev See IProductIRSModule
 */

contract ProductIRSModule is IProductIRSModule {
    using RateOracleReader for RateOracleReader.Data;
    using Portfolio for Portfolio.Data;
    using SafeCastI256 for int256;

    /**
     * @inheritdoc IProductIRSModule
     */
    function initiateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 baseAmount
    )
        external
        override
        returns (int256 executedBaseAmount, int256 executedQuoteAmount)
    {
        // update rate oracle cache if empty or hasn't been updated in a while
        RateOracleReader.load(marketId).updateCache(maturityTimestamp);

        // check if market id is valid + check there is an active pool with maturityTimestamp requested
        address _poolAddress = ProductConfiguration.getPoolAddress();
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        IPool pool = IPool(_poolAddress);
        (executedBaseAmount, executedQuoteAmount) = pool.executeDatedTakerOrder(marketId, maturityTimestamp, baseAmount);
        portfolio.updatePosition(marketId, maturityTimestamp, executedBaseAmount, executedQuoteAmount);

        // propagate order
        address _proxy = ProductConfiguration.getProxyAddress();
        address quoteToken = IMarketConfigurationModule(_proxy).getMarketConfiguration(marketId).quoteToken;
        int256[] memory baseAmounts = new int256[](1);
        baseAmounts[0] = executedBaseAmount;
        int256 annualizedBaseAmount = baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp)[0];
        IProductModule(_proxy).propagateTakerOrder(
            accountId, ProductConfiguration.getProductId(), marketId, quoteToken, annualizedBaseAmount
        );
    }

    /**
     * @inheritdoc IProductIRSModule
     */

    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp, address poolAddress) external override {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        int256 settlementCashflowInQuote = portfolio.settle(marketId, maturityTimestamp, poolAddress);

        address _proxy = ProductConfiguration.getProxyAddress();
        address quoteToken = IMarketConfigurationModule(_proxy).getMarketConfiguration(marketId).quoteToken;

        IProductModule(_proxy).propagateCashflow(accountId, quoteToken, settlementCashflowInQuote);
    }

    /**
     * @inheritdoc IProduct
     */
    function name() external pure override returns (string memory) {
        return "Dated IRS Product";
    }

    /**
     * @inheritdoc IProduct
     */
    // todo: override & add collateralType
    function getAccountUnrealizedPnL(
        uint128 accountId,
        address collateralType
    )
        external
        view
        override
        returns (int256 unrealizedPnL)
    {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = ProductConfiguration.getPoolAddress();
        return portfolio.getAccountUnrealizedPnL(_poolAddress, collateralType);
    }

    /**
     * @inheritdoc IProduct
     */
    function baseToAnnualizedExposure(
        int256[] memory baseAmounts,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        public
        view
        returns (int256[] memory exposures)
    {
        Portfolio.baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp);
    }

    /**
     * @inheritdoc IProduct
     */
    // todo: override & add collateralType
    function getAccountAnnualizedExposures(
        uint128 accountId,
        address collateralType
    )
        external
        view
        override
        returns (Account.Exposure[] memory exposures)
    {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = ProductConfiguration.getPoolAddress();
        return portfolio.getAccountAnnualizedExposures(_poolAddress, collateralType);
    }

    /**
     * @inheritdoc IProduct
     */
    function closeAccount(uint128 accountId, address collateralType) external override {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = ProductConfiguration.getPoolAddress();
        portfolio.closeAccount(_poolAddress, collateralType);
    }

    // todo: introduce in interface or create separate module for exposing this function
    function configureProduct(ProductConfiguration.Data memory config) external {
        ProductConfiguration.set(config);
        emit ProductConfigured(config);
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165) returns (bool) {
        return interfaceId == type(IProduct).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
