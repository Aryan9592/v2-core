// SPDX-License-Identifier: Apache-2.0

pragma solidity =0.8.17;
import "src/products/externalInterfaces/IAaveV3LendingPool.sol";
import "oz/interfaces/IERC20.sol";
import { UD60x18, ud } from "@prb/math/UD60x18.sol";

/// @notice This Mock Aave pool can be used in 3 ways
/// - change the rate to a fixed value (`setReserveNormalizedIncome`)
/// - configure the rate to alter over time (`setFactorPerSecondInRay`) for more dynamic testing
contract MockAaveLendingPool is IAaveV3LendingPool {
    mapping(address => UD60x18) internal reserveNormalizedIncome;
    // mapping(IERC20 => uint256) internal reserveNormalizedVariableDebt;
    mapping(address => uint40) internal startTime;
    mapping(address => UD60x18) internal factorPerSecond; // E.g. 1000000001000000000 for 0.0000001% per second = ~3.2% APY

    function getReserveNormalizedIncome(address _underlyingAsset)
        public
        view
        override
        returns (uint256)
    {
        UD60x18 factor = factorPerSecond[_underlyingAsset];
        UD60x18 currentIndex = reserveNormalizedIncome[_underlyingAsset];
        if (factor.unwrap() > 0) {
            uint256 secondsSinceNormalizedIncomeSet = block.timestamp -
                startTime[_underlyingAsset];
            currentIndex = reserveNormalizedIncome[_underlyingAsset].mul(factor.powu(secondsSinceNormalizedIncomeSet));
        }

        // Convert from UD60x18 to Aave's "Ray" (decmimal scaled by 10^27) to confrom to Aave interface
        return currentIndex.intoUint256() * 1e9;
    }

    function setReserveNormalizedIncome(
        IERC20 _underlyingAsset,
        UD60x18 _reserveNormalizedIncomeInWeiNotRay
    ) public {
        reserveNormalizedIncome[address(_underlyingAsset)] = _reserveNormalizedIncomeInWeiNotRay;
        startTime[address(_underlyingAsset)] = uint40(block.timestamp);
    }

    function setFactorPerSecondInRay(
        IERC20 _underlyingAsset,
        UD60x18 _factorPerSecond
    ) public {
        factorPerSecond[address(_underlyingAsset)] = _factorPerSecond;
    }
}
