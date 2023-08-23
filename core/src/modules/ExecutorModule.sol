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
        /**
         * @dev Identifies the command to be executed
         */
        bytes1 commandType;
        /**
         * @dev Account that is affected by the command. Each individual command
         * execution checks if the account is the actual affected account.
         */
        uint128 accountId;
        /**
         * @dev Command inputs encoded in bytes
         */
        bytes inputs;
        /**
         * @dev Address of the contract that executes the command
         */
        address receivingContract;
        /**
         * @dev Reference to another command in an array using the same accountId.
         * When negative, no reference is given, the command's account id is preserved.
         * When positive, the command's accountId is taken from the referenced command.
         * By using the reference, repeating the IM check can be avoided, but using it
         * is not mandatory.
         */
        int256 referenceIndex;
    }

    function execute(
        Command[] calldata commands
    ) external returns (bytes[] memory outputs) {

        uint128[] memory affectedAccounts = verifyAccounts(commands);

        outputs = new bytes[](commands.length);
        for (uint256 i = 0; i < commands.length; i++) {
            /// @dev if referenced, use the referenced accountId value
            uint128 accountId = commands[i].referenceIndex >= 0 ?
                commands[commands[i].referenceIndex.toUint()].accountId :
                commands[i].accountId;

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

    /**
     * note Checks that every command has a valid account id and creates the list of
     * account ids to be checked for IM
     */ 
    function verifyAccounts(Command[] calldata commands) internal pure returns (uint128[] memory affectedAccounts) {
        affectedAccounts = new uint128[](commands.length);
        for (uint256 i = 0; i < commands.length; i++) {
            // ensure account id is either mentioned or referenced
            require(
                commands[i].referenceIndex >= 0 || commands[i].accountId != 0,
                "Missing Account"
            );

            // ensure account is either not referenced or the referenced one is mentioned
            require(
                commands[i].referenceIndex < 0
                || commands[commands[i].referenceIndex.toUint()].accountId != 0, 
                "Missing Referenced Account"
            );

            // ensure account id is either not referenced or zero (to avoid human error)
            require(commands[i].referenceIndex < 0 || commands[i].accountId == 0, "Confusing Account Id");

            affectedAccounts[i] = commands[i].accountId;
        }
    }
}
