// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @title Constant state
/// @notice Constant state used by the Periphery
library Constants {
    /// @dev Used for identifying cases when this contract's balance of a token is to be used as an input
    /// This value is equivalent to 1<<255, i.e. a singular 1 in the most significant bit.
    uint256 internal constant CONTRACT_BALANCE = 0x8000000000000000000000000000000000000000000000000000000000000000;

    /// @dev Used as a flag for identifying the transfer of ETH instead of a token
    address internal constant ETH = address(0);

    /// @dev Used as a flag for identifying that msg.sender should be used, saves gas by sending more 0 bytes
    address internal constant MSG_SENDER = address(1);

    /// @dev Used as a flag for identifying address(this) should be used, saves gas by sending more 0 bytes
    address internal constant ADDRESS_THIS = address(2);

    /// @dev The length of the bytes encoded address
    uint256 internal constant ADDR_SIZE = 20;
}
