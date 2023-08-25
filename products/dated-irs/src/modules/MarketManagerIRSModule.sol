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
     * @inheritdoc IMarketManagerIRSModule
     */
    function name() external pure override returns (string memory) {
        return "Dated IRS Market Manager";
    }

    /**
     * @inheritdoc IMarketManager
     */
    function isMarketManager() external pure override returns (bool) {
        return true;
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
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
     * @inheritdoc IMarketManagerIRSModule
     */
    function closeAccount(uint128 accountId, uint128 marketId) external override {
        FeatureFlagSupport.ensureEnabledMarket(marketId);
    
        address coreProxy = MarketManagerConfiguration.getCoreProxyAddress();
        if (msg.sender != coreProxy) {
            revert NotAuthorized(msg.sender, "closeAccount");
        }

        Portfolio.exists(accountId, marketId).closeAccount();
    }

    function configureMarketManager(MarketManagerConfiguration.Data memory config) external {
        OwnableStorage.onlyOwner();

        MarketManagerConfiguration.set(config);
        emit MarketManagerConfigured(config, block.timestamp);
    }

    /**
     * @inheritdoc IMarketManagerIRSModule
     */
    function getCoreProxyAddress() external view returns (address) {
        return MarketManagerConfiguration.getCoreProxyAddress();
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return interfaceId == type(IMarketManagerIRSModule).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
