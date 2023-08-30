/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {Account} from "../storage/Account.sol";
import {AutoExchangeConfiguration} from "../storage/AutoExchangeConfiguration.sol";
import {CollateralPool} from "../storage/CollateralPool.sol";
import {Market} from "../storage/Market.sol";
import {IAutoExchangeModule} from "../interfaces/IAutoExchangeModule.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";
import {AutoExchange} from "../libraries/actions/AutoExchange.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UNIT } from "@prb/math/UD60x18.sol";

/**
 * @title Module for auto-exchange, i.e. liquidations of collaterals to address exchange rate risk
 * @dev See IAutoExchangeModule
 */

contract AutoExchangeModule is IAutoExchangeModule {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using Account for Account.Data;
    using Market for Market.Data;

    /**
     * @inheritdoc IAutoExchangeModule
     */
    function isEligibleForAutoExchange(uint128 accountId, address quoteType) external view override returns (
        bool
    ) {
        return Account.exists(accountId).isEligibleForAutoExchange(quoteType);
    }
    
    /**
     * @inheritdoc IAutoExchangeModule
     */
    function getMaxAmountToExchangeQuote(
        uint128 accountId,
        address coveringToken,
        address autoexchangedToken
    ) external view returns (uint256 /* coveringAmount */, uint256 /* autoexchangedAmount */ ) {
        return Account.exists(accountId).getMaxAmountToExchangeQuote(
            coveringToken,
            autoexchangedToken
        );
    }
}
