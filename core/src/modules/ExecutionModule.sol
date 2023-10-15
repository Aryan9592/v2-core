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
import {CreateAccount} from "../libraries/actions/CreateAccount.sol";
import {EditCollateral} from "../libraries/actions/EditCollateral.sol";
import {Market} from "../storage/Market.sol";


contract ExecutionModule is IExecutionModule {

    using Market for Market.Data;
    using Account for Account.Data;

    function execute(
        uint128 accountId,
        Command[] calldata commands
    ) external override returns (bytes[] memory outputs, Account.MarginInfo memory marginInfo) {

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

        if (commandType == CommandType.Create) {
            (address accountOwner) = abi.decode(inputs, (address));
            CreateAccount.createAccount(accountId, accountOwner);
        } else if (commandType == CommandType.Deposit) {
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

        // todo: mark active market

        // todo: fee propagation

        if (command.commandType == CommandType.OnChainTakerOrder) {
            (output,,) = market.executeTakerOrder(accountId, command.inputs);
        } else if (command.commandType == CommandType.OnChainMakerOrder) {
            (output,,) = market.executeMakerOrder(accountId, command.inputs);
        } else if (command.commandType == CommandType.BatchMatchOrder) {
            // todo: add validation
            (
                uint128[] memory makerAccountIds,
                bytes memory orderInputs,
                uint256[] memory exchangeFees // first is account id, the remaining ones are from counterparties
            ) = abi.decode(command.inputs, (uint128[], bytes, uint256[]));
            (output,) = market.executeBatchMatchOrder(accountId, makerAccountIds, orderInputs);

            for (uint256 i = 0; i < makerAccountIds.length; i++) {
                Account.exists(makerAccountIds[i]).imCheck();
            }

        } else if (command.commandType == CommandType.PropagateCashflow) {
            (bytes memory result, int256 cashflowAmount) = market.executePropagateCashflow(accountId, command.inputs);
            account.updateNetCollateralDeposits(market.quoteToken, cashflowAmount);
            output = result;
        } else {
            revert InvalidCommandType();
        }

        return output;

    }



}