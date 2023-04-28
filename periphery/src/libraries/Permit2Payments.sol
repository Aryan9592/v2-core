// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "./Payments.sol";
import "../interfaces/external/IAllowanceTransfer.sol";
import "../storage/Config.sol";

/**
 * @title Payments through Permit2
 * @notice Performs interactions with Permit2 to transfer tokens
 */

library Permit2Payments {
    using SafeCastU256 for uint256;

    error FromAddressIsNotOwner();

    /// @notice Performs a transferFrom on Permit2
    /// @param token The token to transfer
    /// @param from The address to transfer from
    /// @param to The recipient of the transfer
    /// @param amount The amount to transfer
    function permit2TransferFrom(address token, address from, address to, uint160 amount) internal {
        Config.load().PERMIT2.transferFrom(from, to, amount, token);
    }

    /// @notice Either performs a regular payment or transferFrom on Permit2, depending on the payer address
    /// @param token The token to transfer
    /// @param payer The address to pay for the transfer
    /// @param recipient The recipient of the transfer
    /// @param amount The amount to transfer
    function payOrPermit2Transfer(address token, address payer, address recipient, uint256 amount) internal {
        if (payer == address(this)) Payments.pay(token, recipient, amount);
        else permit2TransferFrom(token, payer, recipient, amount.to160());
    }
}
