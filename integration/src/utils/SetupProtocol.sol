pragma solidity >=0.8.19;

import { BatchScript } from "../utils/BatchScript.sol";

import "../../test/fuzzing/Hevm.sol";

import { CoreProxy, AccountNftProxy } from "../proxies/Core.sol";
import { DatedIrsProxy } from "../proxies/DatedIrs.sol";
import { PeripheryProxy } from "../proxies/Periphery.sol";
import { VammProxy } from "../proxies/Vamm.sol";

import { AccessPassNFT } from "@voltz-protocol/access-pass-nft/src/AccessPassNFT.sol";

import { AccessPassConfiguration } from "@voltz-protocol/core/src/storage/AccessPassConfiguration.sol";
import { CollateralPool } from "@voltz-protocol/core/src/storage/CollateralPool.sol";
import { Market } from "@voltz-protocol/core/src/storage/Market.sol";
import { IRateOracle } from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import { AaveV3RateOracle } from "@voltz-protocol/products-dated-irs/src/oracles/AaveV3RateOracle.sol";
import { AaveV3BorrowRateOracle } from "@voltz-protocol/products-dated-irs/src/oracles/AaveV3BorrowRateOracle.sol";
import { IRateOracle } from "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";

import { MarketManagerConfiguration } from
    "@voltz-protocol/products-dated-irs/src/storage/MarketManagerConfiguration.sol";
import { Market as DatedIrsMarket } from "@voltz-protocol/products-dated-irs/src/storage/Market.sol";

import { PoolConfiguration } from "@voltz-protocol/v2-vamm/src/storage/PoolConfiguration.sol";

import { Config } from "@voltz-protocol/periphery/src/storage/Config.sol";

import { Ownable } from "@voltz-protocol/util-contracts/src/ownership/Ownable.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import { UUPSImplementation } from "@voltz-protocol/util-contracts/src/proxy/UUPSImplementation.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";
import { sd } from "@prb/math/SD59x18.sol";

import { TickMath } from "@voltz-protocol/v2-vamm/src/libraries/ticks/TickMath.sol";
import { DatedIrsVamm } from "@voltz-protocol/v2-vamm/src/storage/DatedIrsVamm.sol";

import { Commands } from "@voltz-protocol/periphery/src/libraries/Commands.sol";
import { IWETH9 } from "@voltz-protocol/periphery/src/interfaces/external/IWETH9.sol";

import { Utils } from "./Utils.sol";

contract SetupProtocol is BatchScript {
    struct Contracts {
        CoreProxy coreProxy;
        DatedIrsProxy datedIrsProxy;
        PeripheryProxy peripheryProxy;
        VammProxy vammProxy;
        AaveV3RateOracle aaveV3RateOracle;
        AaveV3BorrowRateOracle aaveV3BorrowRateOracle;
    }

    Contracts public contracts;

    struct Settings {
        bool multisig;
        address multisigAddress;
        bool multisigSend;
        bool echidna;
        bool broadcast;
        bool prank;
    }

    Settings public settings;

    struct Metadata {
        uint256 chainId;
        address owner;
        address sender;
        AccessPassNFT accessPassNft;
        AccountNftProxy accountNftProxy;
    }

    Metadata public metadata;

    bytes32 internal constant _GLOBAL_FEATURE_FLAG = "global";
    bytes32 internal constant _CREATE_ACCOUNT_FEATURE_FLAG = "createAccount";
    bytes32 internal constant _NOTIFY_ACCOUNT_TRANSFER_FEATURE_FLAG = "notifyAccountTransfer";
    bytes32 internal constant _REGISTER_MARKET_MANAGER_FEATURE_FLAG = "registerMarketManager";

    uint16 internal constant MAX_BUFFER_GROWTH_PER_TRANSACTION = 100;

    constructor(Contracts memory _contracts, Settings memory _settings, address owner) {
        contracts = _contracts;
        settings = _settings;

        // todo: Alex
        try contracts.coreProxy.getAccessPassConfiguration() returns (
            AccessPassConfiguration.Data memory accessPassConfig
        ) {
            metadata.accessPassNft = AccessPassNFT(accessPassConfig.accessPassNFTAddress);
        } catch {
            metadata.accessPassNft = AccessPassNFT(vm.envAddress("ACCESS_PASS_NFT"));
        }

        (address accountNftProxyAddress,) = contracts.coreProxy.getAssociatedSystem(bytes32("accountNFT"));
        metadata.accountNftProxy = AccountNftProxy(payable(accountNftProxyAddress));

        metadata.chainId = (settings.multisig || settings.broadcast) ? vm.envUint("CHAIN_ID") : 0;
        metadata.owner = owner;
        metadata.sender = owner;
    }

    function changeSender(address sender) internal {
        metadata.sender = sender;
    }

    function broadcastOrPrank() internal {
        if (settings.broadcast) {
            vm.broadcast(metadata.sender);
        } else if (settings.echidna) {
            hevm.prank(metadata.sender);
        } else if (settings.prank) {
            vm.prank(metadata.sender);
        }
    }

    function execute_multisig_batch() internal {
        if (settings.multisig) {
            executeBatch(settings.multisigAddress, settings.multisigSend, metadata.owner);
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////              HELPERS             /////////////////
    ////////////////////////////////////////////////////////////////////
    function acceptOwnerships() public {
        acceptOwnership(address(contracts.coreProxy));
        acceptOwnership(address(contracts.datedIrsProxy));
        acceptOwnership(address(contracts.vammProxy));
        acceptOwnership(address(contracts.peripheryProxy));
    }

    function enableFeatureFlags(address[] memory pausers) public {
        setFeatureFlagAllowAll({ feature: _GLOBAL_FEATURE_FLAG, allowAll: true });
        setFeatureFlagAllowAll({ feature: _CREATE_ACCOUNT_FEATURE_FLAG, allowAll: true });
        setFeatureFlagAllowAll({ feature: _NOTIFY_ACCOUNT_TRANSFER_FEATURE_FLAG, allowAll: true });

        addToFeatureFlagAllowlist({ feature: _REGISTER_MARKET_MANAGER_FEATURE_FLAG, account: metadata.owner });

        setDeniers({ feature: _GLOBAL_FEATURE_FLAG, deniers: pausers });
    }

    function configureCollateralPool(
        uint128 collateralPoolId,
        UD60x18 imMultiplier,
        UD60x18 mmrMultiplier,
        UD60x18 liquidatorRewardParameter,
        uint256 liquidationBidPriorityQueueDurationInSeconds,
        uint256 maxNumberOfOrdersInLiquidationBid,
        uint256 maxNumberOfBidsInLiquidationBidPriorityQueue,
        uint128 feeCollectorAccountId
    )
        public
    {
        // todo implement once liquidations are completed
        // configureProtocolRisk(
        //   collateralPoolId,
        //   CollateralPool.RiskConfiguration({
        //     imMultiplier:imMultiplier,
        //     mmrMultiplier: mmrMultiplier,
        //     liquidatorRewardParameter: liquidatorRewardParameter,
        //     liquidationBidPriorityQueueDurationInSeconds: liquidationBidPriorityQueueDurationInSeconds,
        //     maxNumberOfOrdersInLiquidationBid: maxNumberOfOrdersInLiquidationBid,
        //     maxNumberOfBidsInLiquidationBidPriorityQueue: maxNumberOfBidsInLiquidationBidPriorityQueue
        //   })
        // );

        periphery_configure(
            Config.Data({
                WETH9: IWETH9(Utils.getWETH9Address(metadata.chainId)),
                VOLTZ_V2_CORE_PROXY: address(contracts.coreProxy),
                VOLTZ_V2_DATED_IRS_PROXY: address(contracts.datedIrsProxy),
                VOLTZ_V2_DATED_IRS_VAMM_PROXY: address(contracts.vammProxy)
            })
        );

        configureAccessPass(AccessPassConfiguration.Data({ accessPassNFTAddress: address(metadata.accessPassNft) }));

        // todo: fee collector account is an interesting edge case when it comes to collateral pool segmentation (AN)
        // create fee collector account owned by protocol owner
        createAccount({ requestedAccountId: feeCollectorAccountId, accountOwner: metadata.owner });
    }

    // todo: alex return new product id to be used in ConfigProtocol.s.sol
    function registerDatedIrsMarketManager(uint256 makerPositionsPerAccountLimit) public {
        // todo: implement once liquidations is completed
        // registerMarketManager(address(contracts.datedIrsProxy), "Dated IRS Market Manager");

        configureMarketManager(MarketManagerConfiguration.Data({ coreProxy: address(contracts.coreProxy) }));

        setPoolConfiguration(
            PoolConfiguration.Data({
                marketManagerAddress: address(contracts.datedIrsProxy),
                makerPositionsPerAccountLimit: makerPositionsPerAccountLimit
            })
        );
    }

    function configureMarket(
        uint128 marketId,
        address tokenAddress,
        bytes32 marketType,
        uint128 feeCollectorAccountId,
        uint256 cap,
        // todo: remove atomicMakerFee, atomicTakerFee (since part of config)
        UD60x18 atomicMakerFee,
        UD60x18 atomicTakerFee,
        UD60x18 riskParameter,
        uint256 maturityIndexCachingWindowInSeconds,
        address rateOracleAddress,
        DatedIrsMarket.MarketConfiguration memory config
    )
        public
    {
        // todo: configure collaterals

        createMarket({ marketId: marketId, quoteToken: tokenAddress, marketType: marketType });

        setMarketConfiguration({
            marketId: marketId,
            marketConfig: DatedIrsMarket.MarketConfiguration({
                poolAddress: address(contracts.vammProxy),
                twapLookbackWindow: config.twapLookbackWindow,
                markPriceBand: config.markPriceBand,
                protocolFeeConfig: config.protocolFeeConfig,
                takerPositionsPerAccountLimit: config.takerPositionsPerAccountLimit,
                positionSizeLowerLimit: config.positionSizeLowerLimit,
                positionSizeUpperLimit: config.positionSizeUpperLimit,
                openInterestUpperLimit: config.openInterestUpperLimit
            })
        });

        setRateOracleConfiguration({
            marketId: marketId,
            rateOracleConfig: DatedIrsMarket.RateOracleConfiguration({
                oracleAddress: rateOracleAddress,
                maturityIndexCachingWindowInSeconds: maturityIndexCachingWindowInSeconds
            })
        });
    }

    function configureMarketMaturity(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint256 riskMatrixRowId,
        uint256 tenorInSeconds,
        UD60x18 phi,
        UD60x18 beta
    )
        public
    {
        setMarketMaturityConfiguration(
            marketId,
            maturityTimestamp,
            DatedIrsMarket.MarketMaturityConfiguration({
                riskMatrixRowId: riskMatrixRowId,
                tenorInSeconds: tenorInSeconds,
                phi: phi,
                beta: beta
            })
        );
    }

    function deployPool(
        DatedIrsVamm.Immutable memory immutableConfig,
        DatedIrsVamm.Mutable memory mutableConfig,
        int24 initTick,
        uint16 observationCardinalityNext,
        uint32[] memory times,
        int24[] memory observedTicks
    )
        public
    {
        createVamm({
            sqrtPriceX96: TickMath.getSqrtRatioAtTick(initTick),
            times: times,
            observedTicks: observedTicks,
            config: immutableConfig,
            mutableConfig: mutableConfig
        });

        (,, uint16 currentObservationCardinalityNext) = contracts.vammProxy.getVammObservationInfo({
            marketId: immutableConfig.marketId,
            maturityTimestamp: immutableConfig.maturityTimestamp
        });

        while (currentObservationCardinalityNext < observationCardinalityNext) {
            uint16 nextObservationCardinalityNext =
                currentObservationCardinalityNext + MAX_BUFFER_GROWTH_PER_TRANSACTION;
            if (nextObservationCardinalityNext > observationCardinalityNext) {
                nextObservationCardinalityNext = observationCardinalityNext;
            }

            increaseObservationCardinalityNext({
                marketId: immutableConfig.marketId,
                maturityTimestamp: immutableConfig.maturityTimestamp,
                observationCardinalityNext: nextObservationCardinalityNext
            });

            currentObservationCardinalityNext = nextObservationCardinalityNext;
        }
    }

    struct MintOrBurnParams {
        uint128 marketId;
        address tokenAddress;
        uint128 accountId;
        uint32 maturityTimestamp;
        uint256 marginAmount;
        int256 notionalAmount; // positive means mint, negative means burn
        int24 tickLower;
        int24 tickUpper;
        address rateOracleAddress;
        uint256 peripheryExecuteDeadline;
    }

    function mintOrBurn(MintOrBurnParams memory params) public returns (bytes memory) {
        IRateOracle rateOracle = IRateOracle(params.rateOracleAddress);

        int256 baseAmount = sd(params.notionalAmount).div(rateOracle.getCurrentIndex().intoSD59x18()).unwrap();

        erc20_approve(IERC20(params.tokenAddress), address(contracts.peripheryProxy), params.marginAmount);

        bytes memory commands;
        bytes[] memory inputs;
        if (Utils.existsAccountNft(metadata.accountNftProxy, params.accountId)) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TRANSFER_FROM)),
                bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
                bytes1(uint8(Commands.V2_VAMM_EXCHANGE_LP))
            );
            inputs = new bytes[](3);
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.V2_CORE_CREATE_ACCOUNT)),
                bytes1(uint8(Commands.TRANSFER_FROM)),
                bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
                bytes1(uint8(Commands.V2_VAMM_EXCHANGE_LP))
            );

            inputs = new bytes[](4);
            inputs[0] = abi.encode(params.accountId);
        }

        inputs[inputs.length - 3] = abi.encode(params.tokenAddress, params.marginAmount);
        inputs[inputs.length - 2] = abi.encode(params.accountId, params.tokenAddress, params.marginAmount);
        inputs[inputs.length - 1] = abi.encode(
            params.accountId, params.marketId, params.maturityTimestamp, params.tickLower, params.tickUpper, baseAmount
        );

        return periphery_execute(commands, inputs, params.peripheryExecuteDeadline)[inputs.length - 1];
    }

    function swap(
        uint128 marketId,
        address tokenAddress,
        uint128 accountId,
        uint32 maturityTimestamp,
        uint256 marginAmount,
        int256 notionalAmount, // positive means VT, negative means FT
        address rateOracleAddress
    )
        public
        returns (bytes memory)
    {
        IRateOracle rateOracle = IRateOracle(rateOracleAddress);

        int256 baseAmount = sd(notionalAmount).div(rateOracle.getCurrentIndex().intoSD59x18()).unwrap();

        erc20_approve(IERC20(tokenAddress), address(contracts.peripheryProxy), marginAmount);

        bytes memory commands;
        bytes[] memory inputs;
        if (Utils.existsAccountNft(metadata.accountNftProxy, accountId)) {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.TRANSFER_FROM)),
                bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
                bytes1(uint8(Commands.V2_DATED_IRS_INSTRUMENT_SWAP))
            );
            inputs = new bytes[](3);
        } else {
            commands = abi.encodePacked(
                bytes1(uint8(Commands.V2_CORE_CREATE_ACCOUNT)),
                bytes1(uint8(Commands.TRANSFER_FROM)),
                bytes1(uint8(Commands.V2_CORE_DEPOSIT)),
                bytes1(uint8(Commands.V2_DATED_IRS_INSTRUMENT_SWAP))
            );

            inputs = new bytes[](4);
            inputs[0] = abi.encode(accountId);
        }
        inputs[inputs.length - 3] = abi.encode(tokenAddress, marginAmount);
        inputs[inputs.length - 2] = abi.encode(accountId, tokenAddress, marginAmount);
        inputs[inputs.length - 1] = abi.encode(accountId, marketId, maturityTimestamp, baseAmount, 0);

        return periphery_execute(commands, inputs, block.timestamp + 100)[inputs.length - 1];
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////               ERC20              /////////////////
    ////////////////////////////////////////////////////////////////////

    function erc20_approve(IERC20 token, address spender, uint256 amount) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            token.approve(spender, amount);
        } else {
            addToBatch(address(token), abi.encodeCall(token.approve, (spender, amount)));
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////          GENERAL PROXY OPS         ///////////////
    ////////////////////////////////////////////////////////////////////

    function upgradeProxy(address proxyAddress, address routerAddress) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            UUPSImplementation(proxyAddress).upgradeTo(routerAddress);
        } else {
            addToBatch(proxyAddress, abi.encodeCall(UUPSImplementation(proxyAddress).upgradeTo, (routerAddress)));
        }
    }

    function acceptOwnership(address ownableProxyAddress) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            Ownable(ownableProxyAddress).acceptOwnership();
        } else {
            addToBatch(ownableProxyAddress, abi.encodeCall(Ownable.acceptOwnership, ()));
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////             CORE PROXY           /////////////////
    ////////////////////////////////////////////////////////////////////

    function initOrUpgradeNft(
        bytes32 id,
        string memory name,
        string memory symbol,
        string memory uri,
        address impl
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.initOrUpgradeNft(id, name, symbol, uri, impl);
        } else {
            addToBatch(
                address(contracts.coreProxy),
                abi.encodeCall(contracts.coreProxy.initOrUpgradeNft, (id, name, symbol, uri, impl))
            );
        }
    }

    function setFeatureFlagAllowAll(bytes32 feature, bool allowAll) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.setFeatureFlagAllowAll(feature, allowAll);
        } else {
            addToBatch(
                address(contracts.coreProxy),
                abi.encodeCall(contracts.coreProxy.setFeatureFlagAllowAll, (feature, allowAll))
            );
        }
    }

    function addToFeatureFlagAllowlist(bytes32 feature, address account) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.addToFeatureFlagAllowlist(feature, account);
        } else {
            addToBatch(
                address(contracts.coreProxy),
                abi.encodeCall(contracts.coreProxy.addToFeatureFlagAllowlist, (feature, account))
            );
        }
    }

    function setDeniers(bytes32 feature, address[] memory deniers) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.setDeniers(feature, deniers);
        } else {
            addToBatch(address(contracts.coreProxy), abi.encodeCall(contracts.coreProxy.setDeniers, (feature, deniers)));
        }
    }

    function configureProtocolRisk(uint128 collateralPoolId, CollateralPool.RiskConfiguration memory config) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.configureCollateralPoolRisk(collateralPoolId, config);
        } else {
            addToBatch(
                address(contracts.coreProxy),
                abi.encodeCall(contracts.coreProxy.configureCollateralPoolRisk, (collateralPoolId, config))
            );
        }
    }

    function configureAccessPass(AccessPassConfiguration.Data memory config) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.configureAccessPass(config);
        } else {
            addToBatch(address(contracts.coreProxy), abi.encodeCall(contracts.coreProxy.configureAccessPass, (config)));
        }
    }

    // todo: implement once liquidations is completed
    // function registerMarketManager(address marketManager, string memory name) public {
    //   if (!settings.multisig) {
    //     broadcastOrPrank();
    //     contracts.coreProxy.registerMarket(marketManager, name);
    //   } else {
    //     addToBatch(
    //       address(contracts.coreProxy),
    //       abi.encodeCall(
    //         contracts.coreProxy.registerMarket,
    //         (marketManager, name)
    //       )
    //     );
    //   }
    // }

    // todo: add collateral configuration support

    function createAccount(uint128 requestedAccountId, address accountOwner) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.coreProxy.createAccount(requestedAccountId, accountOwner);
        } else {
            addToBatch(
                address(contracts.coreProxy),
                abi.encodeCall(contracts.coreProxy.createAccount, (requestedAccountId, accountOwner))
            );
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////             DATED IRS            /////////////////
    ////////////////////////////////////////////////////////////////////

    function configureMarketManager(MarketManagerConfiguration.Data memory config) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.configureMarketManager(config);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(contracts.datedIrsProxy.configureMarketManager, (config))
            );
        }
    }

    function createMarket(uint128 marketId, address quoteToken, bytes32 marketType) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.createMarket(marketId, quoteToken, marketType);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(contracts.datedIrsProxy.createMarket, (marketId, quoteToken, marketType))
            );
        }
    }

    function setMarketConfiguration(uint128 marketId, DatedIrsMarket.MarketConfiguration memory marketConfig) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.setMarketConfiguration(marketId, marketConfig);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(contracts.datedIrsProxy.setMarketConfiguration, (marketId, marketConfig))
            );
        }
    }

    function setMarketMaturityConfiguration(
        uint128 marketId,
        uint32 maturityTimestamp,
        DatedIrsMarket.MarketMaturityConfiguration memory marketMaturityConfig
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.setMarketMaturityConfiguration(marketId, maturityTimestamp, marketMaturityConfig);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(
                    contracts.datedIrsProxy.setMarketMaturityConfiguration,
                    (marketId, maturityTimestamp, marketMaturityConfig)
                )
            );
        }
    }

    function setRateOracleConfiguration(
        uint128 marketId,
        DatedIrsMarket.RateOracleConfiguration memory rateOracleConfig
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.setRateOracleConfiguration(marketId, rateOracleConfig);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(contracts.datedIrsProxy.setRateOracleConfiguration, (marketId, rateOracleConfig))
            );
        }
    }

    function backfillRateIndexAtMaturityCache(
        uint128 marketId,
        uint32 maturityTimestamp,
        UD60x18 rateIndexAtMaturity
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.datedIrsProxy.backfillRateIndexAtMaturityCache(marketId, maturityTimestamp, rateIndexAtMaturity);
        } else {
            addToBatch(
                address(contracts.datedIrsProxy),
                abi.encodeCall(
                    contracts.datedIrsProxy.backfillRateIndexAtMaturityCache,
                    (marketId, maturityTimestamp, rateIndexAtMaturity)
                )
            );
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////                VAMM              /////////////////
    ////////////////////////////////////////////////////////////////////

    function setPoolConfiguration(PoolConfiguration.Data memory config) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.vammProxy.setPoolConfiguration(config);
        } else {
            addToBatch(address(contracts.vammProxy), abi.encodeCall(contracts.vammProxy.setPoolConfiguration, (config)));
        }
    }

    function createVamm(
        uint160 sqrtPriceX96,
        uint32[] memory times,
        int24[] memory observedTicks,
        DatedIrsVamm.Immutable memory config,
        DatedIrsVamm.Mutable memory mutableConfig
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.vammProxy.createVamm(sqrtPriceX96, times, observedTicks, config, mutableConfig);
        } else {
            addToBatch(
                address(contracts.vammProxy),
                abi.encodeCall(
                    contracts.vammProxy.createVamm, (sqrtPriceX96, times, observedTicks, config, mutableConfig)
                )
            );
        }
    }

    function configureVamm(
        uint128 marketId,
        uint32 maturityTimestamp,
        DatedIrsVamm.Mutable memory mutableConfig
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.vammProxy.configureVamm(marketId, maturityTimestamp, mutableConfig);
        } else {
            addToBatch(
                address(contracts.vammProxy),
                abi.encodeCall(contracts.vammProxy.configureVamm, (marketId, maturityTimestamp, mutableConfig))
            );
        }
    }

    function setVammFeatureFlagAllowOne(bytes32 feature, address account) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.vammProxy.addToFeatureFlagAllowlist(feature, account);
        } else {
            addToBatch(
                address(contracts.vammProxy),
                abi.encodeCall(contracts.vammProxy.addToFeatureFlagAllowlist, (feature, account))
            );
        }
    }

    function increaseObservationCardinalityNext(
        uint128 marketId,
        uint32 maturityTimestamp,
        uint16 observationCardinalityNext
    )
        public
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.vammProxy.increaseObservationCardinalityNext(
                marketId, maturityTimestamp, observationCardinalityNext
            );
        } else {
            addToBatch(
                address(contracts.vammProxy),
                abi.encodeCall(
                    contracts.vammProxy.increaseObservationCardinalityNext,
                    (marketId, maturityTimestamp, observationCardinalityNext)
                )
            );
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////             PERIPHERY            /////////////////
    ////////////////////////////////////////////////////////////////////

    function periphery_configure(Config.Data memory config) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            contracts.peripheryProxy.configure(config);
        } else {
            addToBatch(address(contracts.peripheryProxy), abi.encodeCall(contracts.peripheryProxy.configure, (config)));
        }
    }

    function periphery_execute(
        bytes memory commands,
        bytes[] memory inputs,
        uint256 deadline
    )
        public
        returns (bytes[] memory output)
    {
        if (!settings.multisig) {
            broadcastOrPrank();
            output = contracts.peripheryProxy.execute(commands, inputs, deadline);
        } else {
            addToBatch(
                address(contracts.peripheryProxy),
                abi.encodeCall(contracts.peripheryProxy.execute, (commands, inputs, deadline))
            );
        }
    }

    ////////////////////////////////////////////////////////////////////
    /////////////////          ACCESS PASS NFT         /////////////////
    ////////////////////////////////////////////////////////////////////

    function addNewRoot(AccessPassNFT.RootInfo memory rootInfo) public {
        if (!settings.multisig) {
            broadcastOrPrank();
            metadata.accessPassNft.addNewRoot(rootInfo);
        } else {
            addToBatch(address(metadata.accessPassNft), abi.encodeCall(metadata.accessPassNft.addNewRoot, (rootInfo)));
        }
    }
}
