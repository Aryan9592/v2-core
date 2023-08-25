/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/external/ICommandExecutionModule.sol";
import "../storage/Account.sol";
import "./CollateralModule.sol";
import "./AccountModule.sol";
import "../libraries/actions/EditCollateral.sol";
import "../libraries/actions/Liquidation.sol";
import "../libraries/actions/CloseAccount.sol";
import "../libraries/actions/AutoExchange.sol";

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Executor Module
 * @dev Module for managing external protocol interaction.
 */
contract ExecutionModule {

    using Account for Account.Data;
    using SafeCastI256 for int256;

    error InvalidCommandType(uint256 commandType);

    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;
    // Command Types. Maximum supported command at this moment is 64.
    uint256 constant V2_CORE_CREATE_ACCOUNT = 0x00;
    uint256 constant V2_CORE_DEPOSIT = 0x01;
    uint256 constant V2_CORE_WITHDRAW = 0x02;
    uint256 constant V2_CORE_AUTO_EXCHANGE = 0x03;
    uint256 constant V2_CORE_LIQUIDATE = 0x04;
    uint256 constant V2_CORE_CLOSE_ACCOUNT = 0x05;
    // core permission required when interacting with the market manager
    uint256 constant V2_CORE_GRANT_PERMISSION_TO_CORE = 0x06;
    uint256 constant V2_CORE_REVOKE_PERMISSION_FROM_CORE = 0x07;

    struct Command {
        /**
         * @dev Identifies the command to be executed
         */
        bytes1 commandType;
        /**
         * @dev Command inputs encoded in bytes
         */
        bytes inputs;
        /**
         * @dev Market id that identifies the market manager to execute
         * this command. If zero, the command will be sent to core.
         */
        uint128 marketId;
    }


    function operate(
        uint128 accountId,
        Command[] calldata commands
    ) external returns (bytes[] memory outputs, Account.MarginRequirement memory marginRequirement) {

        outputs = new bytes[](commands.length);
        for (uint256 i = 0; i < commands.length; i++) {

            if (commands[i].marketId == 0) {
                executeCoreCommand(
                    accountId,
                    commands[i].commandType,
                    commands[i].inputs
                );
            } else {
                FeatureFlagSupport.ensureGlobalAccess();
                Account.Data storage account = 
                    Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);
                account.ensureEnabledCollateralPool();

                // ensure marketId & accountId are in the same collateral type

                address marketManagerAddress = Market.exists(commands[i].marketId).marketManagerAddress;
                outputs[i] = ICommandExecutionModule(marketManagerAddress)
                    .executeCommand(
                        accountId,
                        commands[i].commandType,
                        commands[i].inputs
                    );
            }
        }

        marginRequirement = Account.exists(accountId).imCheck(address(0));
    }

    /// @dev executes given command & signals if affected account id is wrong
    function executeCoreCommand(
        uint128 accountId,
        bytes1 commandType,
        bytes calldata inputs
    ) internal {
        FeatureFlagSupport.ensureGlobalAccess();
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

        if (command != V2_CORE_CREATE_ACCOUNT) {
            Account.Data storage account = Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);
            account.ensureEnabledCollateralPool();
        }

        if (command == V2_CORE_CREATE_ACCOUNT) {
            bytes32 accountMode;
            assembly {
                accountMode := calldataload(inputs.offset)
            }
            CreateAccount.createAccount(accountId, msg.sender, accountMode);
        } else if (command == V2_CORE_DEPOSIT) {
            address collateralType;
            uint256 tokenAmount;
            assembly {
                collateralType := calldataload(inputs.offset)
                tokenAmount := calldataload(add(inputs.offset, 0x20))
            }
            EditCollateral.deposit(accountId, collateralType, tokenAmount);
        } else if (command == V2_CORE_WITHDRAW) {
            address collateralType;
            uint256 tokenAmount;
            assembly {
                collateralType := calldataload(inputs.offset)
                tokenAmount := calldataload(add(inputs.offset, 0x20))
            }
            EditCollateral.withdraw(accountId, collateralType, tokenAmount);
        } else if (command == V2_CORE_AUTO_EXCHANGE) {
            uint128 liquidatorAccountId;
            uint256 amountToAutoExchangeQuote;
            address collateralType;
            address quoteType;
            assembly {
                liquidatorAccountId := calldataload(inputs.offset)
                amountToAutoExchangeQuote := calldataload(add(inputs.offset, 0x20))
                collateralType := calldataload(add(inputs.offset, 0x40))
                quoteType := calldataload(add(inputs.offset, 0x60))
            }
            AutoExchange.triggerAutoExchange(
                accountId,
                liquidatorAccountId,
                amountToAutoExchangeQuote,
                collateralType,
                quoteType
            );
        } else if (command == V2_CORE_LIQUIDATE) {
            uint128 liquidatorAccountId;
            address collateralType;
            assembly {
                liquidatorAccountId := calldataload(inputs.offset)
                collateralType := calldataload(add(inputs.offset, 0x20))
            }
            Liquidation.liquidate(
                accountId,
                liquidatorAccountId,
                collateralType
            );
        } else if (command == V2_CORE_CLOSE_ACCOUNT) {
            uint128 marketId;
            assembly {
                marketId := calldataload(inputs.offset)
            }
            CloseAccount.closeAccount(
                marketId,
                accountId
            );
        } else if (command == V2_CORE_GRANT_PERMISSION_TO_CORE) {
            Account.exists(accountId).grantPermission(Account.ADMIN_PERMISSION, address(this));
        } else if (command == V2_CORE_REVOKE_PERMISSION_FROM_CORE) {
            Account.exists(accountId).revokePermission(Account.ADMIN_PERMISSION, address(this));
        } else {
            revert InvalidCommandType(command);
        }
    }

}
