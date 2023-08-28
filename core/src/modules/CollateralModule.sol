/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {ICollateralModule} from "../interfaces/ICollateralModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {ERC20Helper} from "@voltz-protocol/util-contracts/src/token/ERC20Helper.sol";

/**
 * @title Module for managing user collateral.
 * @dev See ICollateralModule.
 */
contract CollateralModule is ICollateralModule {
    using ERC20Helper for address;
    using Account for Account.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountCollateralBalance(uint128 accountId, address collateralType)
        external
        view
        override
        returns (uint256 collateralBalance)
    {
        return Account.exists(accountId).getCollateralBalance(collateralType);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountWithdrawableCollateralBalance(uint128 accountId, address collateralType)
        external
        override
        view
        returns (uint256 collateralBalanceAvailable)
    {
        return Account.exists(accountId).getWithdrawableCollateralBalance(collateralType);
    }
}
