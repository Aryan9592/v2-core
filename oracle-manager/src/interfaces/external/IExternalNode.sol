/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "../../storage/NodeOutput.sol";
import "../../storage/NodeDefinition.sol";

/// @title Interface for an external node
interface IExternalNode is IERC165 {
    function process(
        NodeOutput.Data[] memory parentNodeOutputs,
        bytes memory parameters
    ) external view returns (NodeOutput.Data memory);

    function isValid(NodeDefinition.Data memory nodeDefinition) external returns (bool);
}