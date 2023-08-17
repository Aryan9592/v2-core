/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {IMarketConfigurationModule} from "../interfaces/IMarketConfigurationModule.sol";
import {Market} from "../storage/Market.sol";

import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";

/**
 * @title Module for configuring a market
 * @dev See IMarketConfigurationModule.
 */
contract MarketConfigurationModule is IMarketConfigurationModule {
    using Market for Market.Data;

    function createMarket(uint128 marketId, address quoteToken) external override {
        OwnableStorage.onlyOwner();
        Market.create(marketId, quoteToken);
    }

    /**
     * @inheritdoc IMarketConfigurationModule
     */
    function setMarketConfiguration(uint128 marketId, Market.MarketConfiguration memory marketConfig) external override {
        OwnableStorage.onlyOwner();
        Market.Data storage market = Market.exists(marketId);
        market.setMarketConfiguration(marketConfig);
    }

    /**
     * @inheritdoc IMarketConfigurationModule
     */
    function getMarketConfiguration(uint128 marketId) external view override returns (Market.MarketConfiguration memory) {
        Market.Data storage market = Market.exists(marketId);
        return market.marketConfig;
    }
}
