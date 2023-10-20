/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/

pragma solidity >=0.8.19;

// @dev Reserved account id to represent the blended long ADL order
uint128 constant BlendedADLLongId = type(uint128).max - 1;
// @dev Reserved account id to represent the blended short ADL order
uint128 constant BlendedADLShortId = type(uint128).max - 2;