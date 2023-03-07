//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "../interfaces/IProductIRSModule.sol";
import "../../../core/storage/Account.sol";
import "../storage/Portfolio.sol";
import "../storage/MarketConfiguration.sol";
import "../storage/PoolConfiguration.sol";
import "../storage/RateOracleReader.sol";
import "../../../utils/contracts/src/helpers/SafeCast.sol";
import "../../../core/interfaces/IProductModule.sol";

/**
 * @title Dated Interest Rate Swap Product
 * @dev See IProductIRSModule
 */

contract ProductIRSModule is IProductIRSModule {
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
        uint256 maturityTimestamp,
        int256 baseAmount
    )
        external
        override
        returns (int256 executedBaseAmount, int256 executedQuoteAmount)
    {
        // update rate oracle cache if empty or hasn't been updated in a while
        RateOracleReader.load(marketId).updateCache(maturityTimestamp);

        // check if market id is valid + check there is an active pool with maturityTimestamp requested
        address _poolAddress = PoolConfiguration.getPoolAddress();
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        IPool pool = IPool(_poolAddress);
        (executedBaseAmount, executedQuoteAmount) = pool.executeDatedTakerOrder(marketId, maturityTimestamp, baseAmount);
        portfolio.updatePosition(marketId, maturityTimestamp, executedBaseAmount, executedQuoteAmount);
        IProductModule(_proxy).propagateTakerOrder(accountId, msg.sender);
    }

    /**
     * @inheritdoc IProductIRSModule
     */

    function settle(uint128 accountId, uint128 marketId, uint256 maturityTimestamp) external override {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        int256 settlementCashflowInQuote = portfolio.settle(marketId, maturityTimestamp);

        address quoteToken = MarketConfiguration.load(marketId).quoteToken;

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
    function getAccountUnrealizedPnL(uint128 accountId) external view override returns (int256 unrealizedPnL) {
        Portfolio.Data storage portfolio = Portfolio.load(accountId);
        address _poolAddress = PoolConfiguration.getPoolAddress();
        return portfolio.getAccountUnrealizedPnL(_poolAddress);
    }

    /**
     * @inheritdoc IProduct
     */
    function getAccountAnnualizedExposures(uint128 accountId)
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
    function closeAccount(uint128 accountId) external override {
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
