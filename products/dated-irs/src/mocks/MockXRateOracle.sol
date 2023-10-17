/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/IRateOracle.sol";
import "./IMockXRateOracle.sol";

contract MockXRateOracle is IRateOracle, IMockXRateOracle {
    uint256 private _xChainId;
    address private _xRateOracleAddress;
    address private _operator;

    UD60x18 private _liquidityIndex;

    constructor(uint256 __xChainId, address __xRateOracleAddress, address __operator) {
        _xChainId = __xChainId;
        _xRateOracleAddress = __xRateOracleAddress;
        _operator = __operator;
    }

    /// @inheritdoc IRateOracle
    function hasState() external pure override returns (bool) {
        return false;
    }

    /// @inheritdoc IRateOracle
    function earliestStateUpdate() external pure override returns (uint256) {
        revert NoState();
    }

    /// @inheritdoc IRateOracle
    function updateState() external pure override {
        revert NoState();
    }

    /// @inheritdoc IMockXRateOracle
    function xChainId() external view override returns (uint256) {
        return _xChainId;
    }

    /// @inheritdoc IMockXRateOracle
    function xRateOracleAddress() external view override returns (address) {
        return _xRateOracleAddress;
    }

    /// @inheritdoc IMockXRateOracle
    function operator() external view override returns (address) {
        return _operator;
    }

    /// @inheritdoc IMockXRateOracle
    function mockIndex(UD60x18 __liquidityIndex) external {
        require(msg.sender == _operator, "OO");
        require(__liquidityIndex.gt(_liquidityIndex), "SI");
        _liquidityIndex = __liquidityIndex;
    }

    /// @inheritdoc IRateOracle
    function getCurrentIndex() external view override returns (UD60x18 liquidityIndex) {
        return _liquidityIndex;
    }

    /**
     * @inheritdoc IERC165
     */
    function supportsInterface(bytes4 interfaceId) external pure override(IERC165) returns (bool) {
        return interfaceId == type(IRateOracle).interfaceId || interfaceId == this.supportsInterface.selector;
    }
}
