/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IExchangeManagerModule} from "../interfaces/IExchangeManagerModule.sol";
import {Exchange} from "../storage/Exchange.sol";
import {ExchangeStore} from "../storage/ExchangeStore.sol";
import {Account} from "../storage/Account.sol";


contract ExchangeManagerModule is IExchangeManagerModule {

    using Exchange for Exchange.Data;

    /**
     * @inheritdoc IExchangeManagerModule
     */
    function getLastCreatedExchangeId() external view override returns (uint128) {
        return ExchangeStore.getExchangeStore().lastCreatedExchangeId;
    }

    /**
     * @inheritdoc IExchangeManagerModule
     */
    function registerExchange(uint128 exchangeFeeCollectorAccountId) external returns (uint128 exchangeId) {

        exchangeId = Exchange.create(exchangeFeeCollectorAccountId).id;

        Exchange.exists(exchangeId).passCheck();

        emit ExchangeRegistered(exchangeId, block.timestamp);

    }


}