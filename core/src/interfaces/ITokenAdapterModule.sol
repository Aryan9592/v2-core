/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

interface ITokenAdapterModule {
    function registerToken(address token, bytes32 tokenType) external;

    function getTokenType(address token) external view returns(bytes32);

    function convertToShares(address token, uint256 assets) external view returns (uint256);

    function convertToAssets(address token, uint256 shares) external view returns (uint256);
}
