/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ITokenAdapter} from "../../interfaces/ITokenAdapter.sol";
import {IAToken} from "../../interfaces/external/IAToken.sol";

import {mulDiv} from "@prb/math/UD60x18.sol";

contract AaveTokenAdapter is ITokenAdapter {
    address internal _asset;

    constructor(address assetTokenAddress) {
        _asset = assetTokenAddress;
    }

    function asset() external override view returns(address) {
        return _asset;
    } 

    function convertToShares(uint256 assets) external override view returns (uint256) {
        uint256 totalSupply = IAToken(_asset).totalSupply();

        if (totalSupply == 0) {
            return assets;
        }

        uint256 totalShares = IAToken(_asset).scaledTotalSupply();

        return mulDiv(assets, totalShares, totalSupply); 
    } 

    function convertToAssets(uint256 shares) external override view returns (uint256) {
        uint256 totalShares = IAToken(_asset).scaledTotalSupply();

        if (totalShares == 0) {
            return shares;
        } 

        uint256 totalSupply = IAToken(_asset).totalSupply();

        return mulDiv(shares, totalSupply, totalShares); 
    }
}
