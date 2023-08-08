/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import "../interfaces/IFeeConfigurationModule.sol";
import "../storage/Market.sol";

contract FeeConfigurationModule is IFeeConfigurationModule {
    using CollateralPool for CollateralPool.Data;
    using Market for Market.Data;

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function configureProtocolMarketFee(uint128 marketId, Market.FeeConfiguration memory config) external override {
        OwnableStorage.onlyOwner();
        Market.exists(marketId).setProtocolFeeConfiguration(config);
    }

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function configureCollateralPoolMarketFee(uint128 marketId, Market.FeeConfiguration memory config) external override {
        Market.Data storage market = Market.exists(marketId);
        market.getCollateralPool().onlyOwner();
        market.setProtocolFeeConfiguration(config);
    }

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function getProtocolMarketFeeConfiguration(uint128 marketId)
        external
        view
        override
        returns (Market.FeeConfiguration memory config)
    {
        return Market.exists(marketId).protocolFeeConfig;
    }

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function getCollateralPoolMarketFeeConfiguration(uint128 marketId)
        external
        view
        override
        returns (Market.FeeConfiguration memory config)
    {
        return Market.exists(marketId).collateralPoolFeeConfig;
    }
}
