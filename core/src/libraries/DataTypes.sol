/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

/**
 * @dev Data structure for tracking each user's permissions.
 */
struct AccountPermissions {
    /**
     * @dev The address for which all the permissions are granted.
     */
    address user;
    /**
     * @dev The array of permissions given to the associated address.
     */
    bytes32[] permissions;
}

struct PnLComponents {
    int256 realizedPnL;
    /// @notice Unrealized PnL is the valued accumulated in an open position when that position
    /// is priced at market values (’mark to market’). As opposed to the previous components of PnL,
    /// this component changes with time, as market prices change. Strictly speaking, then, unrealized PnL
    /// is actually a function of time: unrealizedPnL(t).
    int256 unrealizedPnL;
}

struct PVMRComponents {
    uint256 long;
    uint256 short;
}

struct UnfilledExposureComponents {
    int256[] long;
    int256[] short;
}

struct UnfilledExposure {
    uint256[] riskMatrixRowIds;
    UnfilledExposureComponents exposureComponents;
    PVMRComponents pvmrComponents;
}

struct RawInformation {
    /// The value of margin balance with no haircuts applied to exchange rates
    int256 rawMarginBalance;
    /// The value of the liquidation margin requirement with no haircuts applied
    /// to exchange rates
    uint256 rawLiquidationMarginRequirement;
}

struct MarginInfo {
    address collateralType;
    CollateralInfo collateralInfo;
    /// Difference between margin balance and initial margin requirement
    int256 initialDelta;
    /// Difference between margin balance and maintenance margin requirement
    int256 maintenanceDelta;
    /// Difference between margin balance and liquidation margin requirement
    int256 liquidationDelta;
    /// Difference between margin balance and dutch margin requirement
    int256 dutchDelta;
    /// Difference between margin balance and adl margin requirement
    int256 adlDelta;
    /// Difference between margin balance and initial buffer margin requirement (for backstop lps)
    int256 initialBufferDelta;
    /// Information required to compute health of position in the context of adl liquidations
    RawInformation rawInfo;
}

struct CollateralInfo {
    int256 netDeposits;
    /// These are all amounts that are available to contribute to cover margin requirements.
    int256 marginBalance;
    /// The real balance is the balance that is in ‘cash’, that is, actually held in the settlement
    /// token and not as value of an instrument which settles in that token
    int256 realBalance;
}
