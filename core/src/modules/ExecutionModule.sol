/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./AccountModule.sol";
import "../interfaces/external/IMarketManager.sol";
import "../libraries/actions/EditCollateral.sol";
import "../libraries/actions/AutoExchange.sol";
import "../libraries/actions/MatchedOrders.sol";
import "../libraries/Propagation.sol";


/**
 * @title Executor Module
 * @dev Module for managing batched user actions with a given collateral pool & markets that belong
 * to that collateral pool
 */
// todo: need an IExecutionModule interface to inherit from + natspec that goes with it
contract ExecutionModule {
    using Market for Market.Data;
    using Account for Account.Data;
    using AccountExposure for Account.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    /**
     * @notice Thrown when a specified command type is not supported by the system.
     */
    error InvalidCommandType(uint256 commandType);
    /**
     * @notice Thrown when trying to modify an account in a market that’s not part of the collateral pool that
     * the account belongs to.
     */
    error CollateralPoolMismatch(uint128 accountId, uint128 marketId);

    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;
    // Command Types. Maximum supported command at this moment is 64.
    // todo: would it be a good idea to leave 0 as some special op?
    uint256 constant V2_CORE_CREATE_ACCOUNT = 0x00;
    uint256 constant V2_CORE_DEPOSIT = 0x01;
    uint256 constant V2_CORE_WITHDRAW = 0x02;
    uint256 constant V2_CORE_AUTO_EXCHANGE = 0x03;
    // todo: adjust this command to be aligned with the new liquidation logic
    uint256 constant V2_CORE_LIQUIDATE = 0x04;
    // todo: remove this command
    uint256 constant V2_CORE_CLOSE_ACCOUNT = 0x05;
    // core permission required when interacting with the market manager
    uint256 constant V2_CORE_GRANT_PERMISSION_TO_CORE = 0x06;
    uint256 constant V2_CORE_REVOKE_PERMISSION_FROM_CORE = 0x07;
    // marker manager commands
    uint256 constant V2_MARKET_MANAGER_TAKER_ORDER = 0x08;
    uint256 constant V2_MARKET_MANAGER_MAKER_ORDER = 0x09;
    // todo: shouldn't be 0x0A?
    uint256 constant V2_MARKET_MANAGER_COMPLETE_POSITION = 0xA0;
    uint256 constant V2_MATCHED_ORDER = 0xA0;

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
    ) external returns (bytes[] memory outputs, Account.MarginInfo memory marginInfo) {
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
                outputs[i] = executeMarketCommand(
                    accountId,
                    commands[i]
                );
            }
        }

        marginInfo = Account.exists(accountId).imCheck(address(0));
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

    /// @dev executes given command in core
    function executeCoreCommand(
        uint128 accountId,
        bytes1 commandType,
        bytes calldata inputs
    ) internal {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

        if (command == V2_CORE_CREATE_ACCOUNT) {
            CreateAccount.createAccount(accountId, msg.sender);
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
        } else if (command == V2_CORE_GRANT_PERMISSION_TO_CORE) {
            Account.exists(accountId).grantPermission(Account.ADMIN_PERMISSION, address(this));
        } else if (command == V2_CORE_REVOKE_PERMISSION_FROM_CORE) {
            Account.exists(accountId).revokePermission(Account.ADMIN_PERMISSION, address(this));
        } else {
            revert InvalidCommandType(command);
        }
    }

    /// @dev executes given command in the market manager associated with the market id
    function executeMarketCommand(
        uint128 accountId,
        Command calldata command
    ) internal returns (bytes memory) {
        Account.Data storage account = Account.exists(accountId);
        if (account.getCollateralPool().id != Market.exists(command.marketId).getCollateralPool().id) {
            revert CollateralPoolMismatch(accountId, command.marketId);
        }
        IMarketManager marketManager = IMarketManager(Market.exists(command.marketId).marketManagerAddress);
        address collateralType = marketManager.getMarketQuoteToken(command.marketId);
        account.markActiveMarket(collateralType, command.marketId);

        uint256 initialAccountMarketExposure = account.getTotalAbsoluteMarketExposure(command.marketId);

        uint256 commandName = uint8(command.commandType & COMMAND_TYPE_MASK);
        if (commandName == V2_MARKET_MANAGER_TAKER_ORDER) {
            (bytes memory result,) = 
                marketManager.executeTakerOrder(accountId, command.marketId, command.inputs);
            uint256 fee = Propagation.propagateTakerOrder(
                accountId,
                command.marketId,
                collateralType, 
                getAnnualizedNotionalDelta(account, command.marketId, initialAccountMarketExposure)
            );
            return abi.encode(result, fee);
        } else if (commandName == V2_MARKET_MANAGER_MAKER_ORDER) {
            (bytes memory result,) = 
                marketManager.executeMakerOrder(accountId, command.marketId, command.inputs);
            uint256 fee = Propagation.propagateMakerOrder(
                accountId,
                command.marketId,
                collateralType, // of the market
                getAnnualizedNotionalDelta(account, command.marketId, initialAccountMarketExposure)
            );
            return abi.encode(result, fee);
        } else if (commandName == V2_MARKET_MANAGER_COMPLETE_POSITION) {
            (bytes memory result, int256 cashflowAmount) = 
                marketManager.completeOrder(accountId, command.marketId, command.inputs);

            account.updateNetCollateralDeposits(collateralType, cashflowAmount);

            return abi.encode(result);
        } else if (commandName == V2_MATCHED_ORDER) {
            (bytes memory matchResult, uint128 counterPartyAccountId, uint256 initialCounterPartyMarketExposure) = 
                MatchedOrders.matchedOrder(
                    accountId,
                    command.marketId,
                    marketManager,
                    command.inputs
                );

            // charge fees
            int256 annualizedNotional = 
                getAnnualizedNotionalDelta(account, command.marketId, initialAccountMarketExposure);
            uint256 fee = Propagation.propagateTakerOrder(
                accountId,
                command.marketId,
                collateralType, 
                annualizedNotional
            );
            int256 counterpartyAnnualizedNotional = getAnnualizedNotionalDelta(
                Account.exists(counterPartyAccountId),
                command.marketId,
                initialCounterPartyMarketExposure
            );
            uint256 counterPartyFee = Propagation.propagateMakerOrder(
                counterPartyAccountId,
                command.marketId,
                collateralType,
                counterpartyAnnualizedNotional
            );

            // run counter party IM
            Account.MarginRequirementDeltas memory counterPartyMarginRequirements = 
                Account.exists(counterPartyAccountId).imCheck(address(0));
                
            return abi.encode(matchResult, fee, counterPartyFee, counterPartyMarginRequirements);
        } else {
            revert InvalidCommandType(commandName);
        }
    }

    /// @notice utility function
    function getAnnualizedNotionalDelta(
        Account.Data storage account,
        uint128 marketId,
        uint256 initialExposure
    ) private view returns (int256 delta) {
        delta = initialExposure.toInt() - 
                account.getTotalAbsoluteMarketExposure(marketId).toInt();
    }

}