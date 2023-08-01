/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "forge-std/Test.sol";
import "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import "@voltz-protocol/util-contracts/src/ownership/Ownable.sol";
import "../../src/oracles/AaveV3RateOracle.sol";
import "../../src/modules/ProductIRSModule.sol";
import "../../src/interfaces/IRateOracleModule.sol";
import "../../src/storage/MarketConfiguration.sol";
import "@voltz-protocol/core/src/interfaces/external/IProduct.sol";
import "@voltz-protocol/core/src/modules/AccountModule.sol";
import "@voltz-protocol/core/src/storage/AccountRBAC.sol";
import "@voltz-protocol/core/src/modules/ProductModule.sol";
import "oz/interfaces/IERC20.sol";
import "../mocks/MockRateOracle.sol";
import "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import "@voltz-protocol/core/src/modules/RiskConfigurationModule.sol";
import { UD60x18, unwrap } from "@prb/math/UD60x18.sol";
import { sd } from "@prb/math/SD59x18.sol";

contract ProductIRSModuleExtended is ProductIRSModule {
    function setOwner(address account) external {
        OwnableStorage.Data storage ownable = OwnableStorage.load();
        ownable.owner = account;
    }

    function getProductConfig() external returns (ProductConfiguration.Data memory) {
        return ProductConfiguration.load();
    }

    function createRateOracle(uint128 marketId, address oracleAddress, uint256 maturityIndexCachingWindowInSeconds)
    external returns (bytes32 s) {
        RateOracleReader.Data storage oracle = RateOracleReader.set(marketId, oracleAddress,
            maturityIndexCachingWindowInSeconds);
        assembly {
            s := oracle.slot
        }
    }

    function createMarket(uint128 marketId, address quoteToken) external {
        MarketConfiguration.set(MarketConfiguration.Data({ marketId: marketId, quoteToken: quoteToken }));
    }

    function loadOrCreatePortfolio(uint128 accountId) external {
        Portfolio.loadOrCreate(accountId);
    }
}

contract MockCoreStorage is AccountModule, ProductModule, RiskConfigurationModule { }

contract ProductIRSModuleTest is Test {
    using ProductConfiguration for ProductConfiguration.Data;

    event ProductConfigured(ProductConfiguration.Data config, uint256 blockTimestamp);

    address constant MOCK_QUOTE_TOKEN = 0x1122334455667788990011223344556677889900;
    address constant MOCK_QUOTE_TOKEN2 = 0x1122334455667788990011223344556677889901;
    uint32 maturityTimestamp;
    uint128 constant MOCK_MARKET_ID = 100;
    uint128 constant MOCK_MARKET_ID2 = 101;
    uint128 constant MOCK_PRODUCT_ID = 123;
    address constant MOCK_USER = address(1234);
    uint128 constant MOCK_ACCOUNT_ID = 1234;

    ProductIRSModuleExtended productIrs;
    MockCoreStorage mockCoreStorage;
    MockRateOracle mockRateOracle;

    function setUp() public virtual {
        maturityTimestamp = Time.blockTimestampTruncated() + 31536000;

        productIrs = new ProductIRSModuleExtended();
        productIrs.setOwner(address(this));

        mockCoreStorage = new MockCoreStorage();

        // create Rate Oracle
        mockRateOracle = new MockRateOracle();
        mockRateOracle.setLastUpdatedIndex(1e18 * 1e9);
        productIrs.createRateOracle(MOCK_MARKET_ID, address(mockRateOracle), 3600);
        productIrs.createRateOracle(MOCK_MARKET_ID2, address(mockRateOracle), 3600);

        // create market
        productIrs.createMarket(MOCK_MARKET_ID, MOCK_QUOTE_TOKEN);
        // create market
        productIrs.createMarket(MOCK_MARKET_ID2, MOCK_QUOTE_TOKEN2);

        // create product
        productIrs.configureProduct(
            ProductConfiguration.Data({
                productId: MOCK_PRODUCT_ID,
                coreProxy: address(mockCoreStorage),
                poolAddress: address(2),
                takerPositionsPerAccountLimit: 2 
            })
        );
    }

    function test_ProductConfiguredCorrectly() public {
        // expect ProductConfigured event
        ProductConfiguration.Data memory config =
            ProductConfiguration.Data({
                productId: 124,
                coreProxy: address(3),
                poolAddress: address(4),
                takerPositionsPerAccountLimit: 3 
            });

        vm.expectEmit(true, true, false, true);
        emit ProductConfigured(config, block.timestamp);

        productIrs.configureProduct(config);

        ProductConfiguration.Data memory configRecived = productIrs.getProductConfig();
        assertEq(configRecived.productId, 124);
        assertEq(configRecived.coreProxy, address(3));
        assertEq(configRecived.poolAddress, address(4));
        assertEq(configRecived.takerPositionsPerAccountLimit, 3);
    }

    function test_SupportsInterfaceIERC165() public {
        assertTrue(productIrs.supportsInterface(type(IERC165).interfaceId));
    }

    function test_SupportsInterfaceIRateOracle() public {
        assertTrue(productIrs.supportsInterface(type(IProduct).interfaceId));
    }

    function test_SupportsOtherInterfaces() public {
        assertFalse(productIrs.supportsInterface(type(IERC20).interfaceId));
    }

    function test_RevertWhen_CloseAccount() public {
        vm.prank(address(7));
        vm.expectRevert();
        productIrs.closeAccount(178, MOCK_QUOTE_TOKEN);
    }

    function test_CloseEmptyAccount() public {
        vm.prank(address(mockCoreStorage));
        vm.expectRevert(abi.encodeWithSelector(Portfolio.PortfolioNotFound.selector, 178));
        productIrs.closeAccount(178, MOCK_QUOTE_TOKEN);
    }

    function test_CloseAccount() public {
        uint128 accountId = 178;
        productIrs.loadOrCreatePortfolio(accountId);
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.isAuthorized.selector,
                accountId, AccountRBAC._ADMIN_PERMISSION, address(this)
            ),
            abi.encode(true)
        );
        productIrs.closeAccount(accountId, MOCK_QUOTE_TOKEN);
    }

    function test_CloseAccount_NoAccount() public {
        uint128 accountId = 178;
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.isAuthorized.selector,
                accountId, AccountRBAC._ADMIN_PERMISSION, address(this)
            ),
            abi.encode(true)
        );
        vm.expectRevert(abi.encodeWithSelector(Portfolio.PortfolioNotFound.selector, accountId));
        productIrs.closeAccount(accountId, MOCK_QUOTE_TOKEN);
    }

    function test_RevertWhen_CloseAccount_NotAllowed() public {
        address peripheryAddress = address(1234);
        uint128 accountId = 178;
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.isAuthorized.selector,
                accountId, AccountRBAC._ADMIN_PERMISSION, address(this)
            ),
            abi.encode(false)
        );
        vm.expectRevert();
        productIrs.closeAccount(accountId, MOCK_QUOTE_TOKEN);
    }

    function test_InitiateTakerOrder() public {
        address thisAddress = address(this);

        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.onlyAuthorized.selector, MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, MOCK_USER
            ),
            abi.encode()
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, 100, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateTakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 10
            ),
            abi.encode(0, 0, 0)
        );
        vm.startPrank(MOCK_USER);

        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
        vm.stopPrank();
    }

    function test_InitiateTakerOrder_market2() public {
        address thisAddress = address(this);

        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.onlyAuthorized.selector, MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, MOCK_USER
            ),
            abi.encode()
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID2, maturityTimestamp, 100, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateTakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID2, MOCK_QUOTE_TOKEN2, 10
            ),
            abi.encode(0, 0, 0)
        );
        vm.startPrank(MOCK_USER);

        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID2,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
        vm.stopPrank();
    }

    function test_InitiateTakerOrder_NoState() public {
        address thisAddress = address(this);

        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.onlyAuthorized.selector, MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, MOCK_USER
            ),
            abi.encode()
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, 100, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateTakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 10
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(false)
        );
        // todo: bump forge-std and uncomment
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
        //     abi.encode("error")
        // );
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(MOCK_USER);
        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
    }

    function test_InitiateTakerOrder_HasState() public {
        address thisAddress = address(this);

        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.onlyAuthorized.selector, MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, MOCK_USER
            ),
            abi.encode()
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, 100, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateTakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 10
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp - 1)
        );
        vm.expectCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ())
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ()),
            abi.encode()
        );

        vm.prank(MOCK_USER);
        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
    }

    function test_InitiateTakerOrder_NoStateUpdateTooEarly() public {
        address thisAddress = address(this);

        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IAccountModule.onlyAuthorized.selector, MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, MOCK_USER
            ),
            abi.encode()
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, 100, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateTakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 10
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp + 1)
        );
        // todo: bump forge-std and uncomment
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(MOCK_USER);
        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
    }

    function test_RevertWhen_InitiateTakerOrder_NotAllowed() public {
        address thisAddress = address(this);

        vm.expectRevert(abi.encodeWithSelector(
            IAccountModule.PermissionNotGranted.selector,
            MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, address(this)
        ));
        productIrs.initiateTakerOrder(
            IProductIRSModule.TakerOrderParams({
                accountId: MOCK_ACCOUNT_ID,
                marketId: MOCK_MARKET_ID,
                maturityTimestamp: maturityTimestamp,
                baseAmount: 100,
                priceLimit: 0
            })
        );
    }

    function test_InitiateMakerOrder_NoState() public {
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateMakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 100
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(false)
        );
        // todo: bump forge-std and uncomment
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
        //     abi.encode("error")
        // );
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(address(2)); // pranking the product
        productIrs.propagateMakerOrder({
            accountId: MOCK_ACCOUNT_ID,
            marketId: MOCK_MARKET_ID,
            maturityTimestamp: maturityTimestamp,
            baseAmount: 100
        });
    }

    function test_InitiateMakerOrder_HasState() public {
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateMakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 100
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp - 1)
        );
        vm.expectCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ())
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ()),
            abi.encode()
        );

        vm.prank(address(2)); // pranking the product
        productIrs.propagateMakerOrder({
            accountId: MOCK_ACCOUNT_ID,
            marketId: MOCK_MARKET_ID,
            maturityTimestamp: maturityTimestamp,
            baseAmount: 100
        });
    }

    function test_InitiateMakerOrder_NoStateUpdateToEarly() public {
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateMakerOrder.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_MARKET_ID, MOCK_QUOTE_TOKEN, 100
            ),
            abi.encode(0, 0, 0)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp + 1)
        );
        // todo: bump forge-std and uncomment
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(address(2)); // pranking the product
        productIrs.propagateMakerOrder({
            accountId: MOCK_ACCOUNT_ID,
            marketId: MOCK_MARKET_ID,
            maturityTimestamp: maturityTimestamp,
            baseAmount: 100
        });
    }

    function test_CloseExistingAccount() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, -20, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.closeUnfilledBase.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10)
        );

        vm.prank(address(mockCoreStorage));
        productIrs.closeAccount(MOCK_ACCOUNT_ID, MOCK_QUOTE_TOKEN);
    }

    function test_CloseExistingAccount_NoState() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, -20, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.closeUnfilledBase.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(false)
        );
        // todo: bump forge-std and uncommen
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
        //     abi.encode("error")
        // );
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(address(mockCoreStorage));
        productIrs.closeAccount(MOCK_ACCOUNT_ID, MOCK_QUOTE_TOKEN);
    }

    function test_CloseExistingAccount_HasState() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, -20, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.closeUnfilledBase.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp - 1)
        );
        vm.expectCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ())
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.updateState, ()),
            abi.encode()
        );

        vm.prank(address(mockCoreStorage));
        productIrs.closeAccount(MOCK_ACCOUNT_ID, MOCK_QUOTE_TOKEN);
    }

    function test_CloseExistingAccount_NoStateUpdateToEarly() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.executeDatedTakerOrder.selector, MOCK_MARKET_ID, maturityTimestamp, -20, 0),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, -10)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.closeUnfilledBase.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10)
        );

        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.hasState, ()),
            abi.encode(true)
        );
        vm.mockCall(
            address(mockRateOracle),
            abi.encodeCall(mockRateOracle.earliestStateUpdate, ()),
            abi.encode(block.timestamp + 1)
        );
        // todo: bump forge-std and uncommen
        // vm.mockCallRevert(
        //     address(mockRateOracle),
        //     abi.encodeCall(mockRateOracle.updateState, ()),
        //     abi.encode("error")
        // );

        vm.prank(address(mockCoreStorage));
        productIrs.closeAccount(MOCK_ACCOUNT_ID, MOCK_QUOTE_TOKEN);
    }


    function test_AccountAnnualizedExposures() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountUnfilledBaseAndQuote.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 10, 11, 11)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 12)
        );

        (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        ) = productIrs.getAccountTakerAndMakerExposures(MOCK_ACCOUNT_ID, MOCK_QUOTE_TOKEN);

        // todo: layer in asserts (AB)
        //    assertEq(exposures.length, 1);
        //    assertEq(exposures[0].marketId, MOCK_MARKET_ID);
        //    assertEq(exposures[0].filled, 20);
        //    assertEq(exposures[0].unfilledLong, 10);
        //    assertEq(exposures[0].unfilledShort, 11);
    }

    function test_AccountAnnualizedExposuresAllCollaterals() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();
        test_InitiateTakerOrder_market2();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountUnfilledBaseAndQuote.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 10, 11, 11)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountUnfilledBaseAndQuote.selector, MOCK_MARKET_ID2, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 10, 11, 11)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 12)
        );
        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID2, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, 12)
        );

        (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        ) = productIrs.getAccountTakerAndMakerExposuresAllCollaterals(MOCK_ACCOUNT_ID);
    }

    function test_BaseToAnnualizedExposure() public {
        int256[] memory baseAmounts = new int256[](2);
        baseAmounts[0] = 178;
        baseAmounts[1] = 1.5e18;

        int256[] memory exposures = new int256[](baseAmounts.length);
        exposures = productIrs.baseToAnnualizedExposure(baseAmounts, MOCK_MARKET_ID, maturityTimestamp);

        assertEq(exposures.length, 2);
        assertEq(exposures[0], 178);
        assertEq(exposures[1], 1.5e18);
    }


    function test_Name() public {
        string memory name = productIrs.name();

        assertEq(name, "Dated IRS Product");
    }

    function test_Settle() public {
        productIrs.loadOrCreatePortfolio(MOCK_ACCOUNT_ID);
        test_InitiateTakerOrder();

        vm.mockCall(
            address(2),
            abi.encodeWithSelector(IPool.getAccountFilledBalances.selector, MOCK_MARKET_ID, maturityTimestamp, MOCK_ACCOUNT_ID),
            abi.encode(10, -20)
        );
        vm.mockCall(
            address(mockCoreStorage),
            abi.encodeWithSelector(
                IProductModule.propagateSettlementCashflow.selector, MOCK_ACCOUNT_ID, MOCK_PRODUCT_ID, MOCK_QUOTE_TOKEN, -10
            ),
            abi.encode()
        );

        vm.warp(maturityTimestamp + 1);
        vm.prank(MOCK_USER);
        productIrs.settle(MOCK_ACCOUNT_ID, MOCK_MARKET_ID, maturityTimestamp);
    }

    function test_RevertWhen_Settle_NotAllowed() public {
        vm.warp(maturityTimestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(
            IAccountModule.PermissionNotGranted.selector,
            MOCK_ACCOUNT_ID, AccountRBAC._ADMIN_PERMISSION, address(this)
        ));
        productIrs.settle(MOCK_ACCOUNT_ID, MOCK_MARKET_ID, maturityTimestamp);
    }
}
