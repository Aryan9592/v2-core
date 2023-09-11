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
     * @inheritdoc IMarketManager
     */
    function closeAllUnfilledOrders(uint128 marketId, uint128 accountId) external {
        // todo: needs implementation & a return?
    }

    /**
     * @inheritdoc IMarketManager
     */
    function executeLiquidationOrder(
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        uint128 marketId,
        bytes calldata inputs
    ) external returns (bytes memory output) {
        // todo: needs implementation
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
        
        uint32 maturityTimestamp;
        int256 baseAmount;
        uint160 priceLimit;

        assembly {
            maturityTimestamp := calldataload(inputs.offset)
            baseAmount := calldataload(add(inputs.offset, 0x20))
            priceLimit := calldataload(add(inputs.offset, 0x40))
        }
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

        uint32 maturityTimestamp;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
        assembly {
            maturityTimestamp := calldataload(inputs.offset)
            tickLower := calldataload(add(inputs.offset, 0x20))
            tickUpper := calldataload(add(inputs.offset, 0x40))
            liquidityDelta := calldataload(add(inputs.offset, 0x60))
        }

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

        uint32 maturityTimestamp;
        assembly {
            maturityTimestamp := calldataload(inputs.offset)
        }

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
}
