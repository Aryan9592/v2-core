/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/external/IExternalNode.sol";

contract MockExternalNode is IExternalNode {
    NodeOutput.Data private output;

    constructor(int256 price, uint256 timestamp) {
        output.price = price;
        output.timestamp = timestamp;
    }

    function process(
        NodeOutput.Data[] memory,
        bytes memory
    ) external view override returns (NodeOutput.Data memory) {
        return output;
    }

    function isValid(
        NodeDefinition.Data memory nodeDefinition
    ) external pure override returns (bool) {
        return nodeDefinition.nodeType == NodeDefinition.NodeType.EXTERNAL;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165) returns (bool) {
        return
        interfaceId == type(IExternalNode).interfaceId ||
        interfaceId == this.supportsInterface.selector;
    }
}