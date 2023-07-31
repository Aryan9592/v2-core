/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";

interface IMockXRateOracle {
    function xChainId() external view returns (uint256);
    function xRateOracleAddress() external view returns (address);
    function operator() external view returns (address);

    function mockIndex(UD60x18 liquidityIndex) external;
}
