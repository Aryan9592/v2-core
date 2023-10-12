pragma solidity >=0.8.19;

import "../src/utils/SetupProtocol.sol";

import { Merkle } from "murky/Merkle.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

contract ConfigProtocol is SetupProtocol {
    using SetUtil for SetUtil.Bytes32Set;

    SetUtil.Bytes32Set private addressPassNftInfo;
    Merkle private merkle = new Merkle();

    bool private _multisig = vm.envBool("MULTISIG");

    constructor()
        SetupProtocol(
            SetupProtocol.Contracts({
                coreProxy: CoreProxy(payable(vm.envAddress("CORE_PROXY"))),
                datedIrsProxy: DatedIrsProxy(payable(vm.envAddress("DATED_IRS_PROXY"))),
                peripheryProxy: PeripheryProxy(payable(vm.envAddress("PERIPHERY_PROXY"))),
                vammProxy: VammProxy(payable(vm.envAddress("VAMM_PROXY"))),
                aaveV3RateOracle: AaveV3RateOracle(vm.envAddress("AAVE_V3_RATE_ORACLE")),
                aaveV3BorrowRateOracle: AaveV3BorrowRateOracle(vm.envAddress("AAVE_V3_BORROW_RATE_ORACLE"))
            }),
            SetupProtocol.Settings({
                multisig: _multisig,
                multisigAddress: (_multisig) ? vm.envAddress("MULTISIG_ADDRESS") : address(0),
                multisigSend: (_multisig) ? vm.envBool("MULTISIG_SEND") : false,
                echidna: false,
                broadcast: !_multisig,
                prank: false
            }),
            vm.envAddress("OWNER")
        )
    { }

    function run() public {
        // Populate with transactions
    }

    function configure_protocol() public {
        // upgradeProxy(address(contracts.coreProxy), address(0));
        // upgradeProxy(address(contracts.datedIrsProxy), address(0));
        // upgradeProxy(address(contracts.peripheryProxy), address(0));
        // upgradeProxy(address(contracts.vammProxy), address(0));

        acceptOwnerships();

        address[] memory pausers = new address[](0);
        enableFeatureFlags({ pausers: pausers });
        configureCollateralPool({
            collateralPoolId: 1,
            imMultiplier: ud60x18(2e18),
            mmrMultiplier: ud60x18(1.5e18),
            liquidatorRewardParameter: ud60x18(5e16),
            liquidationBidPriorityQueueDurationInSeconds: 3600,
            maxNumberOfOrdersInLiquidationBid: 5,
            maxNumberOfBidsInLiquidationBidPriorityQueue: 10,
            feeCollectorAccountId: 999
        });
        registerDatedIrsMarketManager(1);
        configureMarket({
            tokenAddress: Utils.getUSDCAddress(metadata.chainId),
            marketId: 1,
            marketType: "compounding",
            feeCollectorAccountId: 999,
            cap: 1000e6,
            atomicMakerFee: ud60x18(1e16),
            atomicTakerFee: ud60x18(5e16),
            riskParameter: ud60x18(1e18),
            maturityIndexCachingWindowInSeconds: 3600,
            rateOracleAddress: address(contracts.aaveV3RateOracle),
            config: DatedIrsMarket.MarketConfiguration({
                poolAddress: address(contracts.vammProxy),
                twapLookbackWindow: 120,
                markPriceBand: ud60x18(0.005e18),
                takerPositionsPerAccountLimit: 1,
                positionSizeLowerLimit: 1e6,
                positionSizeUpperLimit: 1e6 * 1e6,
                openInterestUpperLimit: 1e6 * 1e9
            })
        });
        uint32[] memory times = new uint32[](2);
        times[0] = uint32(block.timestamp - 86_400);
        times[1] = uint32(block.timestamp - 43_200);
        int24[] memory observedTicks = new int24[](2);
        observedTicks[0] = -13_860;
        observedTicks[1] = -13_860;
        deployPool({
            immutableConfig: DatedIrsVamm.Immutable({
                maturityTimestamp: 1_688_990_400,
                maxLiquidityPerTick: type(uint128).max,
                tickSpacing: 60,
                marketId: 1
            }),
            mutableConfig: DatedIrsVamm.Mutable({
                priceImpactPhi: ud60x18(1e17), // 0.1
                spread: ud60x18(3e15), // 0.3%
                minSecondsBetweenOracleObservations: 3600,
                minTickAllowed: VammTicks.DEFAULT_MIN_TICK,
                maxTickAllowed: VammTicks.DEFAULT_MAX_TICK,
                inactiveWindowBeforeMaturity: 86_400
            }),
            initTick: -13_860, // price = 4%
            observationCardinalityNext: 16,
            times: times,
            observedTicks: observedTicks
        });
        mintOrBurn(
            MintOrBurnParams({
                marketId: 1,
                tokenAddress: Utils.getUSDCAddress(metadata.chainId),
                accountId: 123,
                maturityTimestamp: 1_688_990_400,
                marginAmount: 10e6,
                notionalAmount: 100e6,
                tickLower: -14_100, // 4.1%
                tickUpper: -13_620, // 3.9%
                rateOracleAddress: address(contracts.aaveV3RateOracle),
                peripheryExecuteDeadline: block.timestamp + 360
            })
        );

        execute_multisig_batch();
    }

    /// @notice this should only be used for testnet (for mainnet
    /// it should be done through cannon)
    function addNewRoot(address[] memory accountOwners, string memory baseMetadataURI) public {
        addressPassNftInfo.add(keccak256(abi.encodePacked(address(0), uint256(0))));
        addressPassNftInfo.add(keccak256(abi.encodePacked(address(metadata.owner), uint256(1))));
        for (uint256 i = 0; i < accountOwners.length; i += 1) {
            bytes32 leaf = keccak256(abi.encodePacked(accountOwners[i], uint256(1)));
            if (!addressPassNftInfo.contains(leaf)) {
                addressPassNftInfo.add(leaf);
            }
        }

        addNewRoot(
            AccessPassNFT.RootInfo({
                merkleRoot: merkle.getRoot(addressPassNftInfo.values()),
                baseMetadataURI: baseMetadataURI
            })
        );
    }
}
