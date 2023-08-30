/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../storage/Account.sol";

/**
 * @title Liquidation Engine interface
 */
interface ILiquidationModule {

    /**
     * @notice Get the im and lm requirements and highest unrealized loss along with the flags for im or lm satisfied 
     * @param accountId The id of the account that is being checked
     * @param collateralType The collateral type of the account that is being checked
     * @return Margin requirement information
     */
    function getRequirementDeltasByBubble(uint128 accountId, address collateralType) 
        external 
        view 
        returns (Account.MarginRequirementDeltas memory);
}
