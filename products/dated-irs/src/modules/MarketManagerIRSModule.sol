/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {IMarketManagerIRSModule, IMarketManager} from "../interfaces/IMarketManagerIRSModule.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Portfolio} from "../storage/Portfolio.sol";
import {Position} from "../storage/Position.sol";
import {Market} from "../storage/Market.sol";
import {MarketManagerConfiguration} from "../storage/MarketManagerConfiguration.sol";
import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import {IAccountModule} from "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";
import {IMarketManagerModule} from "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";

import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import {SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {IERC165} from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

import {Settlement} from "../libraries/actions/Settlement.sol";
import {InitiateMakerOrder} from "../libraries/actions/InitiateMakerOrder.sol";
import {InitiateTakerOrder} from "../libraries/actions/InitiateTakerOrder.sol";
import {ExecuteLiquidationOrder} from "../libraries/actions/ExecuteLiquidationOrder.sol";
import {PropagateADLOrder} from "../libraries/actions/PropagateADLOrder.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";


/*
TODOs
    - rename executeADLOrder to executeADLOrders
    - pause maturity or the whole market if just a single maturity is getting adl'd? should market = maturity?
*/

/**
 * @title Dated Interest Rate Swap Market Manager
 * @dev See IMarketManagerIRSModule
 */

contract MarketManagerIRSModule is IMarketManagerIRSModule {
    using Market for Market.Data;
    using Portfolio for Portfolio.Data;
    using SafeCastI256 for int256;

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
    function getAccountTakerAndMakerExposures(
        uint128 marketId,
        uint128 accountId
    )
        external
        view
        override
        returns (Account.MarketExposure[] memory exposures)
    {
        return Portfolio.exists(accountId, marketId).getAccountTakerAndMakerExposures();
    }

    /**
     * @inheritdoc IMarketManager
     */
    function getAccountPnLComponents(
        uint128 marketId,
        uint128 accountId
    ) external view override returns (Account.PnLComponents memory pnlComponents) {
        return Portfolio.exists( accountId, marketId).getAccountPnLComponents();
    }

    // todo: rm after reimplemenation of exposures (used for testing)
    // todo: remember to propagate (updatePosition) when implementing exposures
    function getTakerPositionInfo(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp
    )
        external
        returns (Position.Data memory)
    {
        Portfolio.Data storage p = Portfolio.exists(accountId, marketId);
        p.updatePosition(maturityTimestamp, 0, 0);
        return p.positions[maturityTimestamp];
    }

    /**
     * @inheritdoc IMarketManager
     */
    function closeAllUnfilledOrders(
        uint128 marketId, 
        uint128 accountId
    ) external override returns (int256 /* closedUnfilledBasePool */) {
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
    ) external override returns (bytes memory output) { /// todo: @arturbeg populate output?
        executionPreCheck(marketId);

        ( 
            uint32 maturityTimestamp,
            int256 baseAmountToBeLiquidated,
            uint160 priceLimit
        ) = abi.decode(inputs, (uint32, int256, uint160));

        ExecuteLiquidationOrder.executeLiquidationOrder(
            ExecuteLiquidationOrder.LiquidationOrderParams({
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
        uint128 marketId,
        bytes calldata inputs
    ) external override view {
        ( 
            uint32 maturityTimestamp,
            int256 baseAmountToBeLiquidated
        ) = abi.decode(inputs, (uint32, int256));

        ExecuteLiquidationOrder.validateLiquidationOrder(
            liquidatableAccountId,
            marketId,
            maturityTimestamp,
            baseAmountToBeLiquidated
        );
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeADLOrder(
        uint128 liquidatableAccountId,
        uint128 marketId,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    ) external override {
        Portfolio.exists(liquidatableAccountId, marketId).executeADLOrder(totalUnrealizedLossQuote, realBalanceAndIF);
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
        return interfaceId == type(IMarketManagerIRSModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }

     /**
     * @inheritdoc IMarketManager
     */
    function executeTakerOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external override returns (
        bytes memory output,
        int256 annualizedNotional
    ) {
        executionPreCheck(marketId);
    
        ( 
            uint32 maturityTimestamp,
            int256 baseAmount,
            uint160 priceLimit
        ) = abi.decode(inputs, (uint32, int256, uint160));

        (
            int256 executedBaseAmount,
            int256 executedQuoteAmount,
            int256 annualizedNotionalTraded
        ) = InitiateTakerOrder.initiateTakerOrder(
            InitiateTakerOrder.TakerOrderParams({
                accountId: accountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                baseAmount: baseAmount,
                priceLimit: priceLimit
            })
        );
        output = abi.encode(executedBaseAmount, executedQuoteAmount);
        annualizedNotional = annualizedNotionalTraded;
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeMakerOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external override returns (
        bytes memory output, 
        int256 annualizedNotional
    ) {
        executionPreCheck(marketId);

        ( 
            uint32 maturityTimestamp,
            int24 tickLower,
            int24 tickUpper,
            int128 liquidityDelta
        ) = abi.decode(inputs, (uint32, int24, int24, int128));

        output = abi.encode();
        annualizedNotional = InitiateMakerOrder.initiateMakerOrder(
            InitiateMakerOrder.MakerOrderParams({
                accountId: accountId,
                marketId: marketId,
                maturityTimestamp: maturityTimestamp,
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: liquidityDelta
            })
        );
    }

    /**
     * @inheritdoc IMarketManager
     */
    function completeOrder(
        uint128 accountId,
        uint128 marketId,
        bytes calldata inputs
    ) external override returns (
        bytes memory output,
        int256 cashflowAmount
    ) {
        executionPreCheck(marketId);

        uint32 maturityTimestamp = abi.decode(inputs, (uint32));

        output = abi.encode();
        cashflowAmount = Settlement.settle(accountId, marketId, maturityTimestamp);
    }

    /// @notice run before each account-changing interaction
    function executionPreCheck(uint128 marketId) internal view {
        // only Core can call these functions
        if (msg.sender != MarketManagerConfiguration.getCoreProxyAddress()) {
            revert NotAuthorized(msg.sender, "execute");
        }
        // ensure market is enabled
        FeatureFlagSupport.ensureEnabledMarket(marketId);
    }

    /**
     * @inheritdoc IMarketManager
     */
    function hasUnfilledOrders(uint128 marketId, uint128 accountId) external view override returns (bool) {
        return Portfolio.exists(accountId, marketId).hasUnfilledOrders();
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function propagateADLOrder(
        uint128 accountId,
        uint128 marketId,
        uint32 maturityTimestamp,
        bool isLong
    ) external override {

        PropagateADLOrder.propagateADLOrder(
            accountId,
            marketId,
            maturityTimestamp,
            isLong
        );

    }

}
