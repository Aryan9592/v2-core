/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {ITokenAdapterModule} from "../interfaces/ITokenAdapterModule.sol";
import {IStEth} from "../interfaces/external/IStEth.sol";
import {IAToken} from "../interfaces/external/IAToken.sol";

import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import {mulDiv} from "@prb/math/UD60x18.sol";

contract TokenAdapterModule is ITokenAdapterModule {
    mapping (address => bytes32) internal _tokenTypes;

    bytes32 constant public STANDARD = "STANDARD";
    bytes32 constant public AAVE = "AAVE"; 
    bytes32 constant public LIDO = "LIDO";

    error UnknwonTokenType(address token, bytes32 tokenType);

    function registerToken(address token, bytes32 tokenType) external {
        OwnableStorage.onlyOwner();

        if (!(tokenType == STANDARD || tokenType == AAVE || tokenType == LIDO)) {
            revert UnknwonTokenType(token, tokenType);
        }
        
        _tokenTypes[token] = tokenType;
    }

    function getTokenType(address token) external view returns(bytes32) {
        return _tokenTypes[token];
    }

    function _totalShares(address token, bytes32 tokenType) private view returns(uint256) {
        if (tokenType == AAVE) {
            return IAToken(token).scaledTotalSupply();
        }
        
        if (tokenType == LIDO) {
            return IStEth(token).getTotalShares();
        }
        
        revert UnknwonTokenType(token, tokenType);
    }

    function convertToShares(address token,  uint256 assets) external view returns (uint256) {
        bytes32 tokenType = _tokenTypes[token];
        
        if (tokenType == STANDARD) {
            return assets;
        }

        uint256 totalSupply = IERC20(token).totalSupply();

        if (totalSupply == 0) {
            return assets;
        }

        uint256 totalShares = _totalShares(token, tokenType);

        return mulDiv(assets, totalShares, totalSupply); 
    } 

    function convertToAssets(address token, uint256 shares) external view returns (uint256) {
        bytes32 tokenType = _tokenTypes[token];
        
        if (tokenType == STANDARD) {
            return shares;
        }

        uint256 totalShares = _totalShares(token, tokenType);

        if (totalShares == 0) {
            return shares;
        } 

        uint256 totalSupply = IERC20(token).totalSupply();

        return mulDiv(shares, totalSupply, totalShares); 
    }
}
