/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

/**
 * note Interface used to avoid calling known contracts (e.g. established ERC20 tokens)
 */
interface IVoltzContract {
    /**
     * @dev Voltz specific function, returns true.
     */
    function isVoltzContract() external view returns (bool);
}


