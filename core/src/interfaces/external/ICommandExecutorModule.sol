/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Module for executing a command
 * @notice Receives commands from Core and executes them using given inputs
 */

interface ICommandExecutorModule {
    /**
     * @notice Executes a command with the given inputs
     * @param accountId Account id that is affected with this command
     * @param commandType Command id that identifies the funtion to be called
     * @param inputs The inputs to execute the command with 
     *
     * Requirements:
     *
     * - `msg.sender` must be Core.
     * - `accontId` must truely be the affected account
     *
     */
    function executeCommand(
        uint128 accountId,
        bytes1 commandType,
        bytes calldata inputs
    ) external returns (bytes memory output);
}
