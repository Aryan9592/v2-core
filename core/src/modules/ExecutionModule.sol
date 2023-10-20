/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IExecutionModule} from "../interfaces/IExecutionModule.sol";
// todo: consider abstracting Account.MarginInfo to a datatype lib
import {Account} from "../storage/Account.sol";
import {Exchange} from "../storage/Exchange.sol";
import {CreateAccount} from "../libraries/actions/CreateAccount.sol";
import {EditCollateral} from "../libraries/actions/EditCollateral.sol";
import {Market} from "../storage/Market.sol";
import {FeeCollectorConfiguration} from "../storage/FeeCollectorConfiguration.sol";
import { UD60x18, unwrap } from "@prb/math/UD60x18.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";


contract ExecutionModule is IExecutionModule {

    using Market for Market.Data;
    using Account for Account.Data;
    using Exchange for Exchange.Data;
    using SafeCastU256 for uint256;

    function execute(
        uint128 accountId,
        Command[] calldata commands
    ) external override returns (bytes[] memory outputs, Account.MarginInfo memory marginInfo) {

        preExecuteCheck(accountId);

        outputs = new bytes[](commands.length);

        for (uint256 i = 0; i < commands.length; i++) {

            if (commands[i].marketId == 0) {
                // do we need outputs for core commands?
                executeCoreCommand(
                    accountId,
                    commands[i].commandType,
                    commands[i].inputs
                );
            } else {
                outputs[i] = executeMarketCommand(
                    accountId,
                    commands[i]
                );
            }

        }

        return (outputs, marginInfo);
    }

    function executeCoreCommand(
        uint128 accountId,
        CommandType commandType,
        bytes calldata inputs
    ) internal {

        if (commandType == CommandType.Deposit) {
            (address collateralType, uint256 tokenAmount) = abi.decode(inputs, (address, uint256));
            EditCollateral.deposit(accountId, collateralType, tokenAmount);
        } else if (commandType == CommandType.Withdraw) {
            (address collateralType, uint256 tokenAmount) = abi.decode(inputs, (address, uint256));
            EditCollateral.withdraw(accountId, collateralType, tokenAmount);
        } else {
            revert InvalidCommandType();
        }

    }

    function executeMarketCommand(
        uint128 accountId,
        Command memory command
    ) internal returns (bytes memory output) {

        Account.Data storage account = Account.exists(accountId);
        if (account.getCollateralPool().id != Market.exists(command.marketId).getCollateralPool().id) {
            revert CollateralPoolMismatch(accountId, command.marketId);
        }
        Market.Data storage market = Market.exists(command.marketId);
        account.markActiveMarket(market.quoteToken, market.id);

        Exchange.exists(command.exchangeId).passCheck();

        if (command.commandType == CommandType.OnChainTakerOrder) {
            (bytes memory result, uint256 exchangeFee, uint256 protocolFee) = market.executeTakerOrder(
                accountId,
                command.exchangeId,
                command.inputs
            );
            distributeOnChainFees(
                account,
                market.quoteToken,
                command.exchangeId,
                exchangeFee,
                protocolFee,
                market.marketManagerAddress
            );
            output = result;
        } else if (command.commandType == CommandType.OnChainMakerOrder) {
            (bytes memory result, uint256 exchangeFee, uint256 protocolFee) = market.executeMakerOrder(
                accountId,
                command.exchangeId,
                command.inputs
            );
            distributeOnChainFees(
                account,
                market.quoteToken,
                command.exchangeId,
                exchangeFee,
                protocolFee,
                market.marketManagerAddress
            );
            output = result;
        } else if (command.commandType == CommandType.BatchMatchOrder) {
            // todo: lists can fit into bytes memory?
            (
                uint128[] memory counterpartyAccountIds,
                bytes memory orderInputs,
                uint256 accountExchangeFee,
                uint256[] memory counterpartyExchangeFees
            ) = abi.decode(command.inputs, (uint128[], bytes, uint256, uint256[]));
            (bytes memory result, uint256 accountProtocolFee, uint256[] memory counterpartyProtocolFees) =
            market.executeBatchMatchOrder(
                accountId,
                counterpartyAccountIds,
                orderInputs
            );
            propagateMatchOrders(
                account,
                PropagateMatchOrdersVars(
                    counterpartyAccountIds,
                    market.quoteToken,
                    command.exchangeId,
                    accountExchangeFee,
                    accountProtocolFee,
                    counterpartyExchangeFees,
                    counterpartyProtocolFees,
                    market.marketManagerAddress,
                    market.id
                )
            );
            output = result;
        } else if (command.commandType == CommandType.PropagateCashflow) {
            (bytes memory result, int256 cashflowAmount) = market.executePropagateCashflow(accountId, command.inputs);
            account.updateNetCollateralDeposits(market.quoteToken, cashflowAmount);
            output = result;
        } else {
            revert InvalidCommandType();
        }

        return output;

    }

    struct PropagateMatchOrdersVars {
        uint128[] counterpartyAccountIds;
        address collateralType;
        uint128 exchangeId;
        uint256 accountExchangeFee;
        uint256 accountProtocolFee;
        uint256[] counterpartyExchangeFees;
        uint256[] counterpartyProtocolFees;
        address instrumentAddress;
        uint128 marketId;
    }

    function propagateMatchOrders(
        Account.Data storage account,
        PropagateMatchOrdersVars memory vars
    ) internal {

        // todo: list lengths validation
        // todo: there's some overlap between this function and distributeOnChainFees, consider tidying up

        Exchange.Data storage exchange = Exchange.exists(vars.exchangeId);

        Account.Data storage exchangeAccount = Account.exists(exchange.exchangeFeeCollectorAccountId);
        Account.Data storage treasuryAccount = FeeCollectorConfiguration.loadAccount();

        uint256 overallExchangeFee = vars.accountExchangeFee;
        uint256 overallProtocolFee = vars.accountProtocolFee;
        account.updateNetCollateralDeposits(vars.collateralType, -(vars.accountExchangeFee+vars.accountProtocolFee).toInt());

        for (uint256 i = 0; i < vars.counterpartyAccountIds.length; i++) {
            Account.Data storage counterpartyAccount = Account.loadAccountAndValidatePermission(
                vars.counterpartyAccountIds[i],
                Account.ADMIN_PERMISSION,
                msg.sender
            );
            counterpartyAccount.markActiveMarket(vars.collateralType, vars.marketId);

            uint128 accountCollateralPoolId = account.getCollateralPool().id;
            uint128 counterpartyCollateralPoolId = counterpartyAccount.getCollateralPool().id;

            if (accountCollateralPoolId != counterpartyCollateralPoolId) {
                revert Account.CollateralPoolMismatch(accountCollateralPoolId, counterpartyCollateralPoolId);
            }

            counterpartyAccount.updateNetCollateralDeposits(
                vars.collateralType,
                -(vars.counterpartyExchangeFees[i]+vars.counterpartyProtocolFees[i]).toInt()
            );
            overallExchangeFee += vars.counterpartyExchangeFees[i];
            overallProtocolFee += vars.counterpartyProtocolFees[i];
            counterpartyAccount.imCheck();
        }

        UD60x18 feeRebate = exchange.feeRebatesPerInstrument[vars.instrumentAddress];

        if (unwrap(feeRebate) != 0) {
            uint256 rebateAmount = mulUDxUint(feeRebate, overallProtocolFee);
            overallExchangeFee += rebateAmount;
            overallProtocolFee -= rebateAmount;
        }

        treasuryAccount.updateNetCollateralDeposits(vars.collateralType, overallProtocolFee.toInt());
        exchangeAccount.updateNetCollateralDeposits(vars.collateralType, overallExchangeFee.toInt());

    }

    function distributeOnChainFees(
        Account.Data storage account,
        address collateralType,
        uint128 exchangeId,
        uint256 exchangeFee,
        uint256 protocolFee,
        address instrumentAddress
    ) internal {

        Exchange.Data storage exchange = Exchange.exists(exchangeId);

        Account.Data storage exchangeAccount = Account.exists(exchange.exchangeFeeCollectorAccountId);
        Account.Data storage treasuryAccount = FeeCollectorConfiguration.loadAccount();

        account.updateNetCollateralDeposits(collateralType, -(exchangeFee+protocolFee).toInt());

        UD60x18 feeRebate = exchange.feeRebatesPerInstrument[instrumentAddress];

        if (unwrap(feeRebate) != 0) {
            uint256 rebateAmount = mulUDxUint(feeRebate, protocolFee);
            exchangeFee += rebateAmount;
            protocolFee -= rebateAmount;
        }

        treasuryAccount.updateNetCollateralDeposits(collateralType, protocolFee.toInt());
        exchangeAccount.updateNetCollateralDeposits(collateralType, exchangeFee.toInt());

    }

    /// @notice checks to be ran before starting the batch execution
    function preExecuteCheck(uint128 accountId) internal view {
        FeatureFlagSupport.ensureGlobalAccess();
        Account.Data storage account =
        Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);
        account.ensureEnabledCollateralPool();
    }


}