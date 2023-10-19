/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { IMarketManagerIRSModule, IMarketManager } from "../interfaces/IMarketManagerIRSModule.sol";
import { IPool } from "../interfaces/IPool.sol";
import { Portfolio } from "../storage/Portfolio.sol";
import { Market } from "../storage/Market.sol";
import { ExposureHelpers } from "../libraries/ExposureHelpers.sol";
import { MarketManagerConfiguration } from "../storage/MarketManagerConfiguration.sol";
import { FeatureFlagSupport } from "../libraries/FeatureFlagSupport.sol";
import "../libraries/DataTypes.sol";

import { Account } from "@voltz-protocol/core/src/storage/Account.sol";

import { OwnableStorage } from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { IERC165 } from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

import { Settlement } from "../libraries/actions/Settlement.sol";
import { InitiateMakerOrder } from "../libraries/actions/InitiateMakerOrder.sol";
import { InitiateTakerOrder } from "../libraries/actions/InitiateTakerOrder.sol";
import { ExecuteLiquidationOrder } from "../libraries/actions/ExecuteLiquidationOrder.sol";
import { PropagateADLOrder } from "../libraries/actions/PropagateADLOrder.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { DecimalMath } from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";

/*
TODOs
    - rename executeADLOrder to executeADLOrders
    - pause maturity or the whole market if just a single maturity is getting adl'd?
*/

/**
 * @title Dated Interest Rate Swap Market Manager
 * @dev See IMarketManagerIRSModule
 */

contract MarketManagerIRSModule is IMarketManagerIRSModule {
    using Market for Market.Data;
    using Portfolio for Portfolio.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.UintSet;

    /**
     * @notice Thrown when an attempt to access a function without authorization.
     */
    error NotAuthorized(address caller, bytes32 functionName);

    /**
     * @inheritdoc IMarketManager
     */
    function name() external pure override returns (string memory) {
        return "Dated IRS Market Manager";
    }

    /**
     * @inheritdoc IMarketManager
     */
    function getMarketQuoteToken(uint128 marketId) external view override returns (address) {
        Market.Data storage market = Market.exists(marketId);
        return market.quoteToken;
    }

    /**
     * @inheritdoc IMarketManager
     */
    function isMarketManager() external pure override returns (bool) {
        return true;
    }

    /**
     * @inheritdoc IMarketManager
     */
    function getAccountTakerExposures(
        uint128 marketId,
        uint128 accountId,
        uint256 riskMatrixDim
    )
        external
        view
        override
        returns (int256[] memory)
    {
        return Portfolio.exists(accountId, marketId).getAccountTakerExposures(riskMatrixDim);
    }

    /**
     * @inheritdoc IMarketManager
     */
    function getAccountMakerExposures(
        uint128 marketId,
        uint128 accountId
    )
        external
        view
        override
        returns (Account.UnfilledExposure[] memory)
    {
        return Portfolio.exists(accountId, marketId).getAccountMakerExposures();
    }

    /**
     * @inheritdoc IMarketManager
     */
    function getAccountPnLComponents(
        uint128 marketId,
        uint128 accountId
    )
        external
        view
        override
        returns (Account.PnLComponents memory pnlComponents)
    {
        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        Market.Data storage market = Market.exists(portfolio.marketId);

        address poolAddress = market.marketConfig.poolAddress;
        uint256 activeMaturitiesCount = portfolio.activeMaturities.length();

        for (uint256 i = 1; i <= activeMaturitiesCount; i++) {
            FilledBalances memory filledBalances =
                portfolio.getAccountFilledBalances(portfolio.activeMaturities.valueAt(i).to32(), poolAddress);

            pnlComponents.realizedPnL += filledBalances.pnl.realizedPnL;
            pnlComponents.unrealizedPnL += filledBalances.pnl.unrealizedPnL;
        }

        return pnlComponents;
    }

    /**
     * @inheritdoc IMarketManager
     */
    function closeAllUnfilledOrders(
        uint128 marketId,
        uint128 accountId
    )
        external
        override
        returns (uint256 /* closedUnfilledBasePool */ )
    {
        Portfolio.Data storage portfolio = Portfolio.exists(accountId, marketId);
        uint256[] memory activeMaturities = portfolio.activeMaturities.values();
        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();
            executionPreCheck(marketId, maturityTimestamp);
        }

        return Portfolio.exists(accountId, marketId).closeAllUnfilledOrders();
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeLiquidationOrder(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes calldata inputs
    )
        external
        override
        returns (bytes memory output)
    {
        /// todo: @arturbeg populate output?
        (uint32 maturityTimestamp, int256 baseAmountToBeLiquidated, uint160 priceLimit) =
            abi.decode(inputs, (uint32, int256, uint160));
        executionPreCheck(marketId, maturityTimestamp);

        ExecuteLiquidationOrder.executeLiquidationOrder(
            LiquidationOrderParams({
                liquidatableAccountId: liquidatableAccountId,
                liquidatorAccountId: liquidatorAccountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                baseAmountToBeLiquidated: baseAmountToBeLiquidated,
                priceLimit: priceLimit
            })
        );
    }

    /**
     * @inheritdoc IMarketManager
     */
    function validateLiquidationOrder(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes calldata inputs
    )
        external
        view
        override
    {
        (uint32 maturityTimestamp, int256 baseAmountToBeLiquidated, uint160 priceLimit) =
            abi.decode(inputs, (uint32, int256, uint160));

        ExecuteLiquidationOrder.validateLiquidationOrder(
            LiquidationOrderParams({
                liquidatableAccountId: liquidatableAccountId,
                liquidatorAccountId: liquidatorAccountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                baseAmountToBeLiquidated: baseAmountToBeLiquidated,
                priceLimit: priceLimit
            })
        );
    }

    function getAnnualizedExposureWadAndPSlippage(
        uint128 marketId,
        bytes calldata inputs
    )
        external
        view
        override
        returns (int256 annualizedExposureWad, UD60x18 pSlippage)
    {
        (uint32 maturityTimestamp, int256 baseToBeLiquidated) = abi.decode(inputs, (uint32, int256));

        int256 annualizedExposure =
            ExposureHelpers.baseToAnnualizedExposure(baseToBeLiquidated, marketId, maturityTimestamp);

        Market.Data storage market = Market.exists(marketId);
        annualizedExposureWad = DecimalMath.changeDecimals(
            annualizedExposure, IERC20(market.quoteToken).decimals(), DecimalMath.WAD_DECIMALS
        );

        pSlippage = ExposureHelpers.getPercentualSlippage(marketId, maturityTimestamp, annualizedExposure);
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeADLOrder(
        uint128 liquidatableAccountId,
        uint128 marketId,
        bool adlNegativeUpnl,
        bool adlPositiveUpnl,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    )
        external
        override
    {
        Portfolio.exists(liquidatableAccountId, marketId).executeADLOrder(
            adlNegativeUpnl, adlPositiveUpnl, totalUnrealizedLossQuote, realBalanceAndIF
        );
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function configureMarketManager(MarketManagerConfiguration.Data memory config) external {
        OwnableStorage.onlyOwner();

        MarketManagerConfiguration.set(config);
        emit MarketManagerConfigured(config, block.timestamp);
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return
            interfaceId == type(IMarketManagerIRSModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeTakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint128 exchangeId,
        bytes calldata inputs
    )
        external
        override
        returns (bytes memory output, uint256 exchangeFee, uint256 protocolFee)
    {
        (uint32 maturityTimestamp, int256 baseDelta, uint160 priceLimit) = abi.decode(inputs, (uint32, int256, uint160));
        executionPreCheck(marketId, maturityTimestamp);

        PositionBalances memory tokenDeltas;

        (tokenDeltas, exchangeFee, protocolFee) = InitiateTakerOrder.initiateTakerOrder(
            TakerOrderParams({
                accountId: accountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                baseDelta: baseDelta,
                priceLimit: priceLimit
            })
        );
        output = abi.encode(tokenDeltas);
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeMakerOrder(
        uint128 accountId,
        uint128 marketId,
        uint128 exchangeId,
        bytes calldata inputs
    )
        external
        override
        returns (bytes memory output, uint256 exchangeFee, uint256 protocolFee)
    {
        (uint32 maturityTimestamp, int24 tickLower, int24 tickUpper, int256 baseDelta) =
            abi.decode(inputs, (uint32, int24, int24, int256));

        output = abi.encode();
        (exchangeFee, protocolFee) = InitiateMakerOrder.initiateMakerOrder(
            MakerOrderParams({
                accountId: accountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                baseDelta: baseDelta
            })
        );
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeBatchMatchOrder(
        uint128 accountId,
        uint128[] memory counterpartyAccountIds,
        uint128 marketId,
        bytes calldata inputs
    )
        external
        returns (bytes memory output, uint256 accountProtocolFees, uint256[] memory counterpartyProtocolFees)
    {
        revert MissingBatchMatchOrderImplementation();
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executePropagateCashflow(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    )
        external
        override
        returns (bytes memory output, int256 cashflowAmount)
    {
        uint32 maturityTimestamp = abi.decode(inputs, (uint32));
        executionPreCheck(marketId, maturityTimestamp);

        output = abi.encode();
        cashflowAmount = Settlement.settle(accountId, marketId, maturityTimestamp);
    }

    /// @notice run before each account-changing interaction
    function executionPreCheck(uint128 marketId, uint32 maturityTimestamp) internal view {
        // only Core can call these functions
        if (msg.sender != MarketManagerConfiguration.getCoreProxyAddress()) {
            revert NotAuthorized(msg.sender, "execute");
        }

        // ensure market is enabled
        FeatureFlagSupport.ensureEnabledMarket(marketId, maturityTimestamp);
    }

    /**
     * @inheritdoc IMarketManager
     */
    function hasUnfilledOrders(uint128 marketId, uint128 accountId) external view override returns (bool) {
        return Portfolio.exists(accountId, marketId).hasUnfilledOrders();
    }

    /**
     * @inheritdoc IMarketManager
     */
    function propagateADLOrder(uint128 accountId, uint128 marketId, bytes calldata inputs) external override {
        // only Core can call this function
        if (msg.sender != MarketManagerConfiguration.getCoreProxyAddress()) {
            revert NotAuthorized(msg.sender, "propagateADLOrder");
        }

        (uint32 maturityTimestamp, bool isLong) = abi.decode(inputs, (uint32, bool));
        PropagateADLOrder.propagateADLOrder(accountId, marketId, maturityTimestamp, isLong);
    }

    function getAccountFilledBalances(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (FilledBalances memory)
    {
        Portfolio.Data storage position = Portfolio.exists(accountId, marketId);
        Market.Data storage market = Market.exists(marketId);
        address poolAddress = market.marketConfig.poolAddress;

        return Portfolio.getAccountFilledBalances(position, maturityTimestamp, poolAddress);
    }

    function getAccountUnfilledBaseAndQuote(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint128 accountId
    )
        external
        view
        returns (UnfilledBalances memory)
    {
        Market.Data storage market = Market.exists(marketId);
        address poolAddress = market.marketConfig.poolAddress;

        return IPool(poolAddress).getAccountUnfilledBaseAndQuote(marketId, maturityTimestamp, accountId);
    }

    function getPercentualSlippage(
        uint128 marketId,
        uint32 maturityTimestamp,
        int256 annualizedExposureWad
    )
        external
        view
        override
        returns (UD60x18)
    {
        return ExposureHelpers.getPercentualSlippage(marketId, maturityTimestamp, annualizedExposureWad);
    }
}
