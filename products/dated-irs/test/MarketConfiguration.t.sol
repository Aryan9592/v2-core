pragma solidity 0.8.17;

import "forge-std/Test.sol";
import "../src/storage/MarketConfiguration.sol";

contract ExposeMarketConfiguration {
    using MarketConfiguration for MarketConfiguration.Data;

    // Exposed functions
    function load(uint128 id) external pure returns (bytes32 s) {
        MarketConfiguration.Data storage market = MarketConfiguration.load(id);
        assembly {
            s := market.slot
        }
    }

    function loadAndGetConfig(uint128 id) external pure returns (MarketConfiguration.Data memory) {
        return MarketConfiguration.load(id);
    }

    function set(MarketConfiguration.Data memory data) external {
        MarketConfiguration.set(data);
    }
}

contract MarketConfigurationTest is Test {
    using MarketConfiguration for MarketConfiguration.Data;

    ExposeMarketConfiguration marketConfiguration;

    address constant MOCK_QUOTE_TOKEN = 0x1122334455667788990011223344556677889900;
    uint128 constant MOCK_MARKET_ID = 100;

    function setUp() public virtual {
        marketConfiguration = new ExposeMarketConfiguration();
        marketConfiguration.set(MarketConfiguration.Data({ marketId: MOCK_MARKET_ID, quoteToken: MOCK_QUOTE_TOKEN }));
    }

    function test_LoadAtCorrectStorageSlot() public {
        bytes32 slot = marketConfiguration.load(MOCK_MARKET_ID);
        assertEq(slot, keccak256(abi.encode("xyz.voltz.MarketConfiguration", MOCK_MARKET_ID)));
    }

    function test_CreatedCorrectly() public {
        MarketConfiguration.Data memory data = marketConfiguration.loadAndGetConfig(MOCK_MARKET_ID);
        assertEq(data.marketId, MOCK_MARKET_ID);
        assertEq(data.quoteToken, MOCK_QUOTE_TOKEN);
    }

    function test_CreateNewMarketDoesNotModifyOldMarket() public {
        uint128 marketId = 300;
        marketConfiguration.set(MarketConfiguration.Data({ marketId: marketId, quoteToken: MOCK_QUOTE_TOKEN }));
        MarketConfiguration.Data memory newMarket = marketConfiguration.loadAndGetConfig(marketId);
        MarketConfiguration.Data memory oldMarket = marketConfiguration.loadAndGetConfig(MOCK_MARKET_ID);

        assertEq(newMarket.marketId, marketId);
        assertEq(newMarket.quoteToken, MOCK_QUOTE_TOKEN);

        assertEq(oldMarket.marketId, MOCK_MARKET_ID);
        assertEq(oldMarket.quoteToken, MOCK_QUOTE_TOKEN);
    }

    function test_RevertWhen_SetNewConfigForOldMarket() public {
        vm.expectRevert(abi.encodeWithSelector(MarketConfiguration.MarketAlreadyExists.selector, MOCK_MARKET_ID));
        marketConfiguration.set(MarketConfiguration.Data({ marketId: MOCK_MARKET_ID, quoteToken: address(1) }));
    }

    function test_RevertWhen_ZeroAddressQuoteToken() public {
        vm.expectRevert("Invalid Market");
        marketConfiguration.set(MarketConfiguration.Data({ marketId: MOCK_MARKET_ID, quoteToken: address(0) }));
    }
}
