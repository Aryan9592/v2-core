/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {IStEth} from "../interfaces/external/IStEth.sol";
import {IAToken} from "../interfaces/external/IAToken.sol";

import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

/**
 * @title Library for handling standard and yield-bearing token types
 */
library TokenTypeSupport {
    bytes32 constant public STANDARD = "STANDARD";
    bytes32 constant public AAVE = "AAVE"; 
    bytes32 constant public LIDO = "LIDO";

    error UnknwonTokenType(address token, bytes32 tokenType);

    function getTotalShares(address token, bytes32 tokenType) private view returns(uint256) {
        if (tokenType == AAVE) {
            return IAToken(token).scaledTotalSupply();
        }
        
        if (tokenType == LIDO) {
            return IStEth(token).getTotalShares();
        }
        
        revert UnknwonTokenType(token, tokenType);
    }

    function convertToShares(address token, bytes32 tokenType, uint256 assets) internal view returns (uint256) {

        if (tokenType == STANDARD) {
            return assets;
        }

        uint256 totalSupply = IERC20(token).totalSupply();

        if (totalSupply == 0) {
            return assets;
        }

        uint256 totalShares = getTotalShares(token, tokenType);

        return assets * totalShares / totalSupply; 
    } 

    function convertToAssets(address token, bytes32 tokenType, uint256 shares) internal view returns (uint256) {

        if (tokenType == STANDARD) {
            return shares;
        }

        uint256 totalShares = getTotalShares(token, tokenType);

        if (totalShares == 0) {
            return shares;
        } 

        uint256 totalSupply = IERC20(token).totalSupply();

        return shares * totalSupply / totalShares; 
    } 
}