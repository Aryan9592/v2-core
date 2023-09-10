/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

/**
 * @title Liquidation Engine interface
 */
interface ILiquidationModule {

    /**
     * @notice Get the initial and liquidation margin requirements and highest unrealized loss
     * (if maker positions were to be filled) along with the flags that specify if the initial or liquidation margin
     * requirements are satisfied.
     * @param accountId The id of the account that is being checked
     * @param collateralType The collateral type for which the margin requirements are checked,
     * where the collateral type is the centre of a given collateral bubble
     * @return Margin requirement information object
     */
    function getRequirementDeltasByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        returns (Account.MarginRequirementDeltas memory);
}
