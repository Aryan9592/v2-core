// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.19;

import "./Constants.sol";
import "./Commands.sol";
import "./Payments.sol";

/**
 * @title This library decodes and executes commands
 * @notice This library is called by the ExecutionModule to efficiently decode and execute a singular command
 */
library Dispatcher {
    error InvalidCommandType(uint256 commandType);
    error BalanceTooLow();

    /// @notice Decodes and executes the given command with the given inputs
    /// @param commandType The command type to execute
    /// @param inputs The inputs to execute the command with
    /// @return output Abi encoding of command output if any
    function dispatch(bytes1 commandType, bytes calldata inputs) internal returns (bytes memory output) {
        uint256 command = uint8(commandType & Commands.COMMAND_TYPE_MASK);

        if (command == Commands.WRAP_ETH) {
            // equivalent: abi.decode(inputs, (uint256))
            uint256 amountMin;
            assembly {
                amountMin := calldataload(inputs.offset)
            }
            Payments.wrapETH(address(this), amountMin);
        } else if (command == Commands.TRANSFER_FROM) {
            // equivalent: abi.decode(inputs, (address, uint160))
            address token;
            uint160 value;
            assembly {
                token := calldataload(inputs.offset)
                value := calldataload(add(inputs.offset, 0x20))
            }
            Payments.transferFrom(token, msg.sender, address(this), value);
        } else {
            // placeholder area for commands ...
            revert InvalidCommandType(command);
        }
    }
}
