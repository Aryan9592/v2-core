pragma solidity >=0.8.19;

import { IERC721 } from "@voltz-protocol/util-contracts/src/interfaces/IERC721.sol";

import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { FullMath } from "@voltz-protocol/v2-vamm/src/libraries/math/FullMath.sol";

import { SafeCastU256, SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

library Utils {
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;

    uint256 internal constant Q96 = 2 ** 96;

    function getWETH9Address(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) {
            return 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        } else if (chainId == 5) {
            return 0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6;
        } else if (chainId == 42_161) {
            return 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        } else if (chainId == 421_613) {
            return 0xb83C277172198E8Ec6b841Ff9bEF2d7fa524f797;
        } else if (chainId == 43_114) {
            return 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
        } else if (chainId == 0) {
            // used for echidna and integration tests
            return 0x0000000000000000000000000000000000000000;
        } else {
            revert("getWETH9Address: Unsupported chain");
        }
    }

    function getUSDCAddress(uint256 chainId) internal pure returns (address) {
        if (chainId == 1) {
            return 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        } else if (chainId == 5) {
            return 0xD87Ba7A50B2E7E660f678A895E4B72E7CB4CCd9C;
        } else if (chainId == 42_161) {
            return 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
        } else if (chainId == 421_613) {
            return 0x72A9c57cD5E2Ff20450e409cF6A542f1E6c710fc;
        } else if (chainId == 43_114) {
            return 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
        } else {
            revert("getUSDCAddress: Unsupported chain");
        }
    }

    function existsAccountNft(IERC721 accountNftProxy, uint256 tokenId) internal view returns (bool) {
        try accountNftProxy.ownerOf(tokenId) {
            return true;
        } catch {
            return false;
        }
    }
}
