//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IProductIRSModule.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import "../storage/Portfolio.sol";
import "../storage/MarketConfiguration.sol";
import "../storage/PoolConfiguration.sol";
import "../storage/RateOracleReader.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/core/src/interfaces/IProductModule.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";
import { SD59x18, unwrap as sUnwrap } from "@prb/math/SD59x18.sol";

/**
 * @title Dated Interest Rate Swap Product
 * @dev See IProductIRSModule
 */

contract ProductIRSModule is IProductIRSModule {
    using { sUnwrap } for SD59x18;
    using RateOracleReader for RateOracleReader.Data;
    using Portfolio for Portfolio.Data;
    using SafeCastI256 for int256;

    address private _proxy;
    uint128 private _productId;

    function initialize(address proxy, uint128 productId) external {
        // todo: do we want to make below two varaibles settable? if yes need to be careful because the core relies on
        // e.g. productId information
        _proxy = proxy;
        _productId = productId;
    }

    /**
     * @inheritdoc IProductIRSModule
     */
    function initiateTakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        SD59x18 baseAmount
    )
        external
        override
        returns (SD59x18 executedBaseAmount, SD59x18 executedQuoteAmount)
    {
        // update rate oracle cache if empty or hasn't been updated in a while
        RateOracleReader.load(marketId).updateCache(maturityTimestamp);

        // check if market id is valid + check there is an active pool with maturityTimestamp requested
        address _poolAddress = PoolConfiguration.getPoolAddress();
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        IPool pool = IPool(_poolAddress);
        (executedBaseAmount, executedQuoteAmount) = pool.executeDatedTakerOrder(marketId, maturityTimestamp, baseAmount);
        portfolio.updatePosition(marketId, maturityTimestamp, executedBaseAmount, executedQuoteAmount);

        // propagate order
        address quoteToken = MarketConfiguration.load(marketId).quoteToken;
        SD59x18[] memory baseAmounts = new SD59x18[](1);
        baseAmounts[0] = executedBaseAmount;
        SD59x18 annualizedBaseAmount = baseToAnnualizedExposure(baseAmounts, marketId, maturityTimestamp)[0];
        IProductModule(_proxy).propagateTakerOrder(accountId, _productId, marketId, quoteToken, annualizedBaseAmount.sUnwrap().toUint());
    }

    /**
     * @inheritdoc IProductIRSModule
     */

    function settle(uint128 accountId, uint128 marketId, uint32 maturityTimestamp) external override {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        SD59x18 settlementCashflowInQuote = portfolio.settle(marketId, maturityTimestamp);

        address quoteToken = MarketConfiguration.load(marketId).quoteToken;

        IProductModule(_proxy).propagateCashflow(accountId, quoteToken, settlementCashflowInQuote.sUnwrap());
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
    function getAccountUnrealizedPnL(uint128 accountId, address collateralType) external view override returns (SD59x18 unrealizedPnL) {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = PoolConfiguration.getPoolAddress();
        return portfolio.getAccountUnrealizedPnL(_poolAddress);
    }

    /**
     * @inheritdoc IProduct
     */
    function baseToAnnualizedExposure(SD59x18[] memory baseAmounts, uint128 marketId, uint32 maturityTimestamp) 
        public view returns (SD59x18[] memory exposures) 
    {
        Portfolio.baseToAnnualizedExposure(baseAmounts, marketId, uint32(maturityTimestamp));
    }

    /**
     * @inheritdoc IProduct
     */
     // todo: override & add collateralType
    function getAccountAnnualizedExposures(uint128 accountId, address collateralType)
        external
        view
        override
        returns (Account.Exposure[] memory exposures)
    {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = PoolConfiguration.getPoolAddress();
        return portfolio.getAccountAnnualizedExposures(_poolAddress);
    }

    /**
     * @inheritdoc IProduct
     */
    function closeAccount(uint128 accountId, address collateralType) external override {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = PoolConfiguration.getPoolAddress();
        portfolio.closeAccount(_poolAddress);
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(IERC165) returns (bool) {
        return interfaceId == type(IProduct).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
