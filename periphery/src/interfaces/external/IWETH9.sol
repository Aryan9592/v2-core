// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

/// @title Interface for WETH9
interface IWETH9 is IERC20 {
    /// @notice Deposit ether to get wrapped ether
    function deposit() external payable;

    /// @notice Withdraw wrapped ether to get ether
    function withdraw(uint256) external;
}
