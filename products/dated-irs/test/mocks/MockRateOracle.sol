/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "../../src/oracles/AaveV3RateOracle.sol";
import "../../src/interfaces/IRateOracle.sol";
import "./MockAaveLendingPool.sol";
import "../../src/interfaces/external/IAaveV3LendingPool.sol";
import { UD60x18, ud } from "@prb/math/UD60x18.sol";

contract MockRateOracle is IRateOracle {
    uint32 public lastUpdatedTimestamp;
    uint256 public lastUpdatedLiquidityIndex;

    /// @inheritdoc IRateOracle
    function hasState() external override pure returns (bool) {
        return false;
    }

    /// @inheritdoc IRateOracle
    function earliestStateUpdate() external override pure returns (uint256) {
        revert NoState();
    }
    
    /// @inheritdoc IRateOracle
    function updateState() external override pure {
        revert NoState();
    }

    function setLastUpdatedIndex(uint256 _lastUpdatedLiquidityIndex) public {
        lastUpdatedLiquidityIndex = _lastUpdatedLiquidityIndex;
    }

    /// @inheritdoc IRateOracle
    function getCurrentIndex() external view override returns (UD60x18 liquidityIndex) {
        return ud(lastUpdatedLiquidityIndex / 1e9);
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external view override(IERC165) returns (bool) {
        return interfaceId == type(IRateOracle).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
