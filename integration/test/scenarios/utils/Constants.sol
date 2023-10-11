pragma solidity >=0.8.19;

/// @title Constant state
/// @notice Constant state used by the Integration tests
library Constants {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint256 internal constant WAD = 1_000_000_000_000_000_000;

    bytes32 internal constant ADMIN_PERMISSION = "ADMIN";
    bytes32 internal constant _PAUSER_FEATURE_FLAG = "pauser";
}