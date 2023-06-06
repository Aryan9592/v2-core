// https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import "../src/storage/Position.sol";

contract PositionTest is Test {
    using Position for Position.Data;

    Position.Data position;

    function setUp() public virtual {
        position = Position.Data({ baseBalance: 167, quoteBalance: -67 });
    }

    function test_Update() public {
        position.update(10, 20);
        assertEq(position.baseBalance, 177);
        assertEq(position.quoteBalance, -47);
    }
}
