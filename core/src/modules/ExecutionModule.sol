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


contract ExecutionModule is IExecutionModule {

    using Market for Market.Data;
    using Account for Account.Data;
    using SafeCastU256 for uint256;

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
            // todo: add validation
            (
                uint128[] memory counterpartyAccountIds,
                bytes memory orderInputs,
                uint256[] memory exchangeFees // first is account id, the remaining ones are from counterparties
            ) = abi.decode(command.inputs, (uint128[], bytes, uint256[]));
            (bytes memory result, uint256[] memory protocolFees) = market.executeBatchMatchOrder(
                accountId,
                counterpartyAccountIds,
                orderInputs
            );

            for (uint256 i = 0; i < counterpartyAccountIds.length; i++) {
                Account.exists(counterpartyAccountIds[i]).imCheck();
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

        UD60x18 feeRebate = exchange.feeRebatesPerInstrument[instrumentAddress];

        if (unwrap(feeRebate) != 0) {
            uint256 rebateAmount = mulUDxUint(feeRebate, protocolFee);
            exchangeFee += rebateAmount;
            protocolFee -= rebateAmount;
        }

        account.updateNetCollateralDeposits(collateralType, -(exchangeFee+protocolFee).toInt());
        treasuryAccount.updateNetCollateralDeposits(collateralType, protocolFee.toInt());
        exchangeAccount.updateNetCollateralDeposits(collateralType, exchangeFee.toInt());

    }


}