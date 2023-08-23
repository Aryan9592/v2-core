/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/external/ICommandExecutorModule.sol";
import "../interfaces/external/IVoltzContract.sol";
import "../storage/Account.sol";
import "./CollateralModule.sol";
import "./AccountModule.sol";

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Executor Module
 * @dev Module for managing external protocol interaction.
 */
contract ExecutorModule {

    using Account for Account.Data;
    using SafeCastI256 for int256;

    error InvalidCommandType(uint256 commandType);
    error NotAVoltzContract(address receivingContract);

    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;
    // Command Types. Maximum supported command at this moment is 0x3f.
    uint256 constant V2_CORE_CREATE_ACCOUNT = 0x00;
    uint256 constant V2_CORE_DEPOSIT = 0x01;
    uint256 constant V2_CORE_WITHDRAW = 0x02;
    // core permission required when interacting with the market manager
    uint256 constant V2_CORE_GRANT_PERMISSION_TO_CORE = 0x03;
    uint256 constant V2_CORE_REVOKE_PERMISSION_FROM_CORE = 0x04;

    struct Command {
        bytes1 commandType;
        uint128 accountId;
        bytes inputs;
        address receivingContract;
        int256 referenceIndex;
    }

    function execute(
        Command[] calldata commands
    ) external returns (bytes[] memory outputs) {

        uint128[] memory affectedAccounts = new uint128[](commands.length);

        outputs = new bytes[](commands.length);
        for (uint256 i = 0; i < commands.length; i++) {
            (uint128 accountId, uint128 affectedAccountId) = 
                getAccountIdByReference(commands, i);
            affectedAccounts[i] = affectedAccountId;

            if (commands[i].receivingContract == address(this)) {
                executeCoreCommand(
                    accountId,
                    commands[i].commandType,
                    commands[i].inputs
                );
            } else {
                // ensures no collision with known contracts
                if (
                    !IERC165(commands[i].receivingContract)
                    .supportsInterface(type(IVoltzContract).interfaceId)
                ) {
                    revert NotAVoltzContract(commands[i].receivingContract);
                }

                outputs[i] = ICommandExecutorModule(commands[i].receivingContract)
                    .executeCommand(
                        accountId,
                        commands[i].commandType,
                        commands[i].inputs
                    );
            }
        }

        for (uint256 i = 0; i < affectedAccounts.length; i++) {
            if (affectedAccounts[i] != 0) {
                Account.load(affectedAccounts[i]).imCheck(address(0));
            }
        }
    }

    /// @dev executes given command & signals if affected account id is wrong
    function executeCoreCommand(
        uint128 affectedAccountId,
        bytes1 commandType,
        bytes calldata inputs
    ) internal {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);
        if (command == V2_CORE_CREATE_ACCOUNT) {
            // equivalent: abi.decode(inputs, (uint128, uint128, bool))
            // todo: double check the input offsets following changes to the core (IR)
            uint128 requestedId;
            bytes32 accountMode;
            assembly {
                requestedId := calldataload(inputs.offset)
                accountMode := calldataload(add(inputs.offset, 0x40))
            }
            require(affectedAccountId == requestedId, "AccountId missmatch");
            AccountModule(address(this)).createAccount(requestedId, msg.sender, accountMode);
        } else if (command == V2_CORE_DEPOSIT) {
            // equivalent: abi.decode(inputs, (uint128, address, uint256))
            uint128 accountId;
            address collateralType;
            uint256 tokenAmount;
            assembly {
                accountId := calldataload(inputs.offset)
                collateralType := calldataload(add(inputs.offset, 0x20))
                tokenAmount := calldataload(add(inputs.offset, 0x40))
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            CollateralModule(address(this)).deposit(accountId, collateralType, tokenAmount);
        } else if (command == V2_CORE_WITHDRAW) {
            // equivalent: abi.decode(inputs, (uint128, address, uint256))
            uint128 accountId;
            address collateralType;
            uint256 tokenAmount;
            assembly {
                accountId := calldataload(inputs.offset)
                collateralType := calldataload(add(inputs.offset, 0x20))
                tokenAmount := calldataload(add(inputs.offset, 0x40))
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            CollateralModule(address(this)).withdraw(accountId, collateralType, tokenAmount);
        } else if (command == V2_CORE_GRANT_PERMISSION_TO_CORE) {
            // equivalent: abi.decode(inputs, (uint128))
            uint128 accountId;
            assembly {
                accountId := calldataload(inputs.offset)
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            IAccountModule(address(this)).grantPermission(accountId, Account.ADMIN_PERMISSION, address(this));
        } else if (command == V2_CORE_REVOKE_PERMISSION_FROM_CORE) {
            // equivalent: abi.decode(inputs, (uint128))
            uint128 accountId;
            assembly {
                accountId := calldataload(inputs.offset)
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            IAccountModule(address(this)).revokePermission(accountId, Account.ADMIN_PERMISSION, address(this));
        }else {
            revert InvalidCommandType(command);
        }

    }

    // todo: explain
    function getAccountIdByReference(
        Command[] calldata commands,
        uint256 index
    ) internal pure returns (
        uint128 accountId,
        uint128 newAffectedAccountId
    ) {
        if(commands[index].referenceIndex >= 0) {
            // reference to another pair
            accountId = commands[commands[index].referenceIndex.toUint()].accountId;
        } else {
            // new account collateral pair
            newAffectedAccountId = commands[index].accountId;
            accountId = commands[index].accountId;
        }
    }
}
