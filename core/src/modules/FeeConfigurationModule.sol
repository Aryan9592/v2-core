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
    using Market for Market.Data;

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function configureMarketFee(uint128 marketId, Market.MarketFeeConfiguration memory config) external override {
        OwnableStorage.onlyOwner();
        Market.exists(marketId).setFeeConfiguration(config);
    }

    /**
     * @inheritdoc IFeeConfigurationModule
     */
    function getMarketFeeConfiguration(uint128 marketId)
        external
        view
        override
        returns (Market.MarketFeeConfiguration memory config)
    {
        return Market.exists(marketId).feeConfig;
    }
}
