/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

// todo: consider abstracting Account.MarginInfo to a datatype lib
import {Account} from "../storage/Account.sol";

interface IExecutionModule {

    /**
     * @notice Thrown when a specified command type is not supported by the system.
     */
    error InvalidCommandType();

    /**
     * @notice Thrown when trying to modify an account in a market that’s not part of the collateral pool that
     * the account belongs to.
     */
    error CollateralPoolMismatch(uint128 accountId, uint128 marketId);

    // Enum representing command type
    enum CommandType {
        Create, // create account in core
        Deposit,  // deposit tokens
        Withdraw, // withdraw tokens
        OnChainTakerOrder, // on-chain taker order (against lps in an on-chain exchange)
        OnChainMakerOrder, // on-chain maker order (liquidity provision/removal operation in an on-chain exchange
        BatchMatchOrder, // propagation of a batch of matched orders
        PropagateCashflow
    }

    struct Command {
        /**
         * @dev Identifies the command to be executed
         */
        CommandType commandType;
        /**
         * @dev Command inputs encoded in bytes
         */
        bytes inputs;
        /**
         * @dev Market id that identifies the market manager to execute
         * this command. If zero, the command will be sent to core.
         */
        uint128 marketId;
        /**
         * @dev Exchange id that identifies the exchange that executes
         * this command. If zero, the command does not involve an exchange (e.g. propagate cashflow)
         */
        uint128 exchangeId;
    }

    function execute(
        uint128 accountId,
        Command[] calldata commands
    ) external returns (bytes[] memory outputs, Account.MarginInfo memory marginInfo);

}