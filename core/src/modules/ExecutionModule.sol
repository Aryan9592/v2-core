/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";
import "./CollateralModule.sol";
import "./AccountModule.sol";
import "../interfaces/external/IMarketManager.sol";
import "../libraries/actions/EditCollateral.sol";
import "../libraries/actions/Liquidation.sol";
import "../libraries/actions/CloseAccount.sol";
import "../libraries/actions/AutoExchange.sol";
import "../libraries/Propagation.sol";

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Executor Module
 * @dev Module for managing external protocol interaction.
 */
contract ExecutionModule {
    using Market for Market.Data;
    using Account for Account.Data;
    using SafeCastI256 for int256;

    /**
     * @notice Thrown when specified command type is not recognized.
     */
    error InvalidCommandType(uint256 commandType);
    /**
     * @notice Thrown when trying to modify an account in a market that's not part of the same collateral pool.
     */
    error CollateralPoolMismatch(uint128 accountId, uint128 marketId);

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
    // marker manager commands
    uint256 constant V2_MARKET_MANAGER_TAKER_ORDER = 0x08;
    uint256 constant V2_MARKET_MANAGER_MAKER_ORDER = 0x09;
    uint256 constant V2_MARKET_MANAGER_COMPLETE_POSITION = 0xA0;

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
        preOperateCheck(accountId);

        outputs = new bytes[](commands.length);
        for (uint256 i = 0; i < commands.length; i++) {
            if (commands[i].marketId == 0) {
                executeCoreCommand(
                    accountId,
                    commands[i].commandType,
                    commands[i].inputs
                );
            } else {
                preCommandExecutionCheck(accountId, commands[i].marketId);

                address marketManagerAddress = Market.exists(commands[i].marketId).marketManagerAddress;
                outputs[i] = executeMarketManagerCommand(
                    accountId,
                    commands[i].marketId,
                    commands[i].commandType,
                    commands[i].inputs,
                    marketManagerAddress
                );
            }
        }

        marginRequirement = Account.exists(accountId).imCheck(address(0));
    }

    /// @notice checks to be ran before starting the batch execution
    function preOperateCheck(uint128 accountId) internal view {
        FeatureFlagSupport.ensureGlobalAccess();
        if (Account.doesExist(accountId)) {
            Account.Data storage account = 
                Account.loadAccountAndValidatePermission(accountId, Account.ADMIN_PERMISSION, msg.sender);
            account.ensureEnabledCollateralPool();
        }
    }

    /// @notice checks to be ran before each command execution
    function preCommandExecutionCheck(uint128 accountId, uint128 marketId) internal view {
        Account.Data storage account = Account.exists(accountId);
        if (account.getCollateralPool().id != Market.exists(marketId).getCollateralPool().id) {
            revert CollateralPoolMismatch(accountId, marketId);
        }
    }

    /// @dev executes given command in core
    function executeCoreCommand(
        uint128 accountId,
        bytes1 commandType,
        bytes calldata inputs
    ) internal {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

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

    /// @dev executes given command in the market manager associated with the market id
    function executeMarketManagerCommand(
        uint128 accountId,
        uint128 marketId,
        bytes1 commandType,
        bytes calldata inputs,
        address marketManagerAddress
    ) internal returns (bytes memory) {
        IMarketManager marketManager = IMarketManager(marketManagerAddress);
        address collateralType = marketManager.getMarketQuoteToken(marketId);

        Account.exists(accountId).markActiveMarket(collateralType, marketId);

        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

        if (command == V2_MARKET_MANAGER_TAKER_ORDER) {
            (bytes memory result, int256 annualizedNotional) = 
                marketManager.executeInitiateTakerOrderCommand(accountId, marketId, inputs);
            uint256 fee = Propagation.propagateTakerOrder(
                accountId,
                marketId,
                collateralType, 
                annualizedNotional
            );
            return abi.encode(result, fee);
        } else if (command == V2_MARKET_MANAGER_MAKER_ORDER) {
            (bytes memory result, int256 annualizedNotional) = 
                marketManager.executeInitiateMakerOrderCommand(accountId, marketId, inputs);
            uint256 fee = Propagation.propagateMakerOrder(
                accountId,
                marketId,
                collateralType, // of the market
                annualizedNotional
            );
            return abi.encode(result, fee);
        } else if (command == V2_MARKET_MANAGER_COMPLETE_POSITION) {
            (bytes memory result, int256 cashflowAmount) = 
                marketManager.executeCompletePositionCommand(accountId, marketId, inputs);
            Propagation.propagateCashflow(
                accountId,
                collateralType, // of the market
                cashflowAmount
            );
            return abi.encode(result);
        } else {
            revert InvalidCommandType(command);
        }
    }

}
