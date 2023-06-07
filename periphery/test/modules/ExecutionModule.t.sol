pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import "../../src/modules/ExecutionModule.sol";
import "../../src/interfaces/external/IWETH9.sol";
import "../../src/modules/ConfigurationModule.sol";
import "../utils/MockAllowanceTransfer.sol";
import "../utils/MockWeth.sol";

contract MockERC20 is ERC20 {
    constructor() ERC20("MockToken", "MT", 18){
        _mint(msg.sender, 1000000000000000000);
    }
}

contract ExtendedExecutionModule is ExecutionModule, ConfigurationModule {
    function setOwner(address account) external {
        OwnableStorage.Data storage ownable = OwnableStorage.load();
        ownable.owner = account;
    }
}

contract ExecutionModuleTest is Test {
    using SafeTransferLib for MockERC20;

    ExtendedExecutionModule exec;
    address core = address(111);
    address instrument = address(112);
    address exchange = address(113);

    MockWeth mockWeth = new MockWeth("MockWeth", "Mock WETH");

    function setUp() public {
        exec = new ExtendedExecutionModule();
        exec.setOwner(address(this));
        exec.configure(Config.Data({
            WETH9: mockWeth,
            PERMIT2: new MockAllowanceTransfer(),
            VOLTZ_V2_CORE_PROXY: core,
            VOLTZ_V2_DATED_IRS_PROXY: instrument,
            VOLTZ_V2_DATED_IRS_VAMM_PROXY: exchange
        }));
    }

    function testExecCommand_Swap() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_DATED_IRS_INSTRUMENT_SWAP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(1, 101, 1678786786, 100, 0);

        vm.mockCall(
            instrument,
            abi.encodeWithSelector(
                IProductIRSModule.initiateTakerOrder.selector,
                1, 101, 1678786786, 100, 0
            ),
            abi.encode(100, -100)
        );

        exec.execute(commands, inputs, deadline);
    }

    function testExecCommand_Settle() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_DATED_IRS_INSTRUMENT_SETTLE)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(1, 101, 1678786786);

        vm.mockCall(
            instrument,
            abi.encodeWithSelector(
                IProductIRSModule.settle.selector,
                1, 101, 1678786786
            ),
            abi.encode(100, -100)
        );

        exec.execute(commands, inputs, deadline);
    }

    function testExecCommand_Mint() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_VAMM_EXCHANGE_LP)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(1, 101, 1678786786);

        vm.mockCall(
            exchange,
            abi.encodeWithSelector(
                IPoolModule.initiateDatedMakerOrder.selector,
                1, 101, 1678786786, -6600, -6000, 10389000
            ),
            abi.encode()
        );

        exec.execute(commands, inputs, deadline);
    }

    function testExecCommand_Withdraw() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_CORE_WITHDRAW)));
        bytes[] memory inputs = new bytes[](1);

        MockERC20 token = new MockERC20();
        token.transfer(address(exec), 100000);
        uint256 initBalanceThis = token.balanceOf(address(this));

        inputs[0] = abi.encode(1, address(token), 100000);

        vm.mockCall(
            core,
            abi.encodeWithSelector(
                ICollateralModule.deposit.selector,
                1, address(token), 100000
            ),
            abi.encode()
        );

        exec.execute(commands, inputs, deadline);

        assertEq(token.balanceOf(address(this)), initBalanceThis + 100000);
        assertEq(token.balanceOf(address(exec)), 0);
    }

    function testExecCommand_Withdraw_Reverted() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_CORE_WITHDRAW)));
        bytes[] memory inputs = new bytes[](1);

        MockERC20 token = new MockERC20();
        token.transfer(address(exec), 100000);
        uint256 initBalanceThis = token.balanceOf(address(this));

        inputs[0] = abi.encode(1, address(token), 100000);

        vm.mockCallRevert(
            core,
            abi.encodeWithSelector(
                ICollateralModule.deposit.selector,
                1, address(token), 100000
            ),
            abi.encode("REVERT_MESSAGE")
        );

        vm.expectRevert();
        exec.execute(commands, inputs, deadline);

        assertEq(token.balanceOf(address(this)), initBalanceThis);
        assertEq(token.balanceOf(address(exec)), 100000);
    }

    function testExecCommand_Deposit() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V2_CORE_DEPOSIT)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(1, address(56), 100000);

        vm.mockCall(
            core,
            abi.encodeWithSelector(
                ICollateralModule.deposit.selector,
                address(this), 1, address(56), 100000
            ),
            abi.encode()
        );

        exec.execute(commands, inputs, deadline);
    }

    function testExecCommand_TransferFrom() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.TRANSFER_FROM)));
        bytes[] memory inputs = new bytes[](1);

        MockERC20 token = new MockERC20();
        token.transfer(address(56), 500);

        vm.mockCall(
            core,
            abi.encodeWithSelector(
                bytes4(abi.encodeWithSignature("transferFrom(address,address,uint160,address)")),
                address(56), address(exec), 50, address(token)
            ),
            abi.encode()
        );
        inputs[0] = abi.encode(address(token), address(56), address(exec), 50);

        exec.execute(commands, inputs, deadline);
    }

    function testExecCommand_WrapETH() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(20000);

        vm.mockCall(
            address(mockWeth),
            20000,
            abi.encodeWithSelector(IWETH9.deposit.selector),
            abi.encode()
        );
        vm.deal(address(this), 20000);
        uint256 initBalance = address(this).balance;
        uint256 initBalanceExec = address(exec).balance;

        exec.execute{value: 20000}(commands, inputs, deadline);

        assertEq(initBalance, address(this).balance + 20000);
        assertEq(initBalanceExec, address(exec).balance - 20000);
    }

    function testExecMultipleCommands() public {
        uint256 deadline = block.timestamp + 1;
        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.WRAP_ETH)), bytes1(uint8(Commands.V2_CORE_DEPOSIT)));
        bytes[] memory inputs = new bytes[](2);
        inputs[0] = abi.encode(20000);
        inputs[1] = abi.encode(1, address(56), 100000);

        vm.mockCall(
            address(mockWeth),
            20000,
            abi.encodeWithSelector(IWETH9.deposit.selector),
            abi.encode()
        );
        vm.mockCall(
            core,
            abi.encodeWithSelector(
                ICollateralModule.deposit.selector,
                address(this), 1, address(56), 100000
            ),
            abi.encode()
        );
        vm.deal(address(this), 20000);
        uint256 initBalance = address(this).balance;
        uint256 initBalanceExec = address(exec).balance;

        exec.execute{value: 20000}(commands, inputs, deadline);

        assertEq(initBalance, address(this).balance + 20000);
        assertEq(initBalanceExec, address(exec).balance - 20000);
    }

    function test_RevertWhen_UnknownCommand() public {
        uint256 deadline = block.timestamp + 1;
        uint256 mockCommand = 0x09;
        bytes memory commands = abi.encodePacked(bytes1(uint8(mockCommand)));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(1, 101, 1678786786, 100, 0);

        vm.expectRevert(abi.encodeWithSelector(
            Dispatcher.InvalidCommandType.selector,
            uint8(bytes1(uint8(mockCommand)) & Commands.COMMAND_TYPE_MASK)
        ));
        exec.execute(commands, inputs, deadline);
    }

}