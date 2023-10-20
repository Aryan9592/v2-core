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
import {ExchangePassConfiguration} from "../storage/ExchangePassConfiguration.sol";
import {INFTPass} from "../interfaces/external/INFTPass.sol";
import {Account} from "../storage/Account.sol";


contract ExchangeManagerModule is IExchangeManagerModule {

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

        address accountOwner = Account.exists(exchangeFeeCollectorAccountId).rbac.owner;

        address exchangePassNFTAddress = ExchangePassConfiguration.exists().exchangePassNFTAddress;

        uint256 ownerExchangePassBalance = INFTPass(exchangePassNFTAddress).balanceOf(accountOwner);
        if (ownerExchangePassBalance == 0) {
            revert OnlyExchangePassOwner();
        }

        exchangeId = Exchange.create(exchangeFeeCollectorAccountId).id;

        emit ExchangeRegistered(exchangeId, block.timestamp);

    }


}