/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ITokenAdapter} from "../../interfaces/ITokenAdapter.sol";

contract StandardTokenAdapter is ITokenAdapter {
    address internal _asset;

    constructor(address assetTokenAddress) {
        _asset = assetTokenAddress;
    }

    function asset() external override view returns(address) {
        return _asset;
    } 

    function convertToShares(uint256 assets) external override pure returns (uint256) {
        return assets; 
    } 

    function convertToAssets(uint256 shares) external override pure returns (uint256) {
        return shares;
    }
}
