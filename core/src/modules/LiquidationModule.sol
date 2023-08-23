/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {CollateralConfiguration} from "../storage/CollateralConfiguration.sol";
import {ILiquidationModule} from "../interfaces/ILiquidationModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: consider introducing explicit reetrancy guards across the protocol
// todo: funnel a portfion of profits from liquidations to the default fund (nedes more research) (AB)
// todo: consider also performing auto-exchange in the event where a multi-token account is liquidatable (AB)
// todo: incorporate multi-token account liquidation flow, for that to work, we'll need to support (AB)
// position transferring liquidations where the incentive of the liquidator is not in terms of a given collateral token
// but rather represented as a discount on the liquidated position's price based on the twap

/**
 * @title Module for liquidated accounts
 * @dev See ILiquidationModule
 */

contract LiquidationModule is ILiquidationModule {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;

    /**
     * @inheritdoc ILiquidationModule
     */
    function getMarginRequirementsAndHighestUnrealizedLoss(uint128 accountId, address collateralType) 
        external 
        view 
        override 
        returns (Account.MarginRequirement memory mr) 
    {
        Account.Data storage account = Account.exists(accountId);
        mr = account.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
    }

}
