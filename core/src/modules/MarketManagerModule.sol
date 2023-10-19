/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Market} from "../storage/Market.sol";
import {MarketStore} from "../storage/MarketStore.sol";
import {IMarketManager} from "../interfaces/external/IMarketManager.sol";
import {IMarketManagerModule} from "../interfaces/IMarketManagerModule.sol";
import {InstrumentRegistrar} from "../storage/InstrumentRegistrar.sol";

import {ERC165Helper} from "@voltz-protocol/util-contracts/src/helpers/ERC165Helper.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Protocol-wide entry point for the management of markets connected to the protocol.
 * @dev See IMarketManagerModule
 */
contract MarketManagerModule is IMarketManagerModule {
    using Market for Market.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.UintSet;

    /**
     * @inheritdoc IMarketManagerModule
     */
    function getLastCreatedMarketId() external view override returns (uint128) {
        return MarketStore.getMarketStore().lastCreatedMarketId;
    }

    /**
     * @inheritdoc IMarketManagerModule
     */
    function registerMarket(
        address marketManager, 
        address quoteToken, 
        string memory name
    ) external override returns (uint128 marketId) {
        if (!ERC165Helper.safeSupportsInterface(marketManager, type(IMarketManager).interfaceId)) {
            revert IncorrectMarketInterface(marketManager);
        }

        InstrumentRegistrar.exists(marketManager);

        // todo: force registration to go through the instrument

        marketId = Market.create(marketManager, quoteToken, name, msg.sender).id;

        emit MarketRegistered(marketManager, marketId, quoteToken, name, msg.sender, block.timestamp);
    }
}
