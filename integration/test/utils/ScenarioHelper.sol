pragma solidity >=0.8.19;

import "forge-std/Test.sol";

import {DeployProtocol} from "../../src/utils/DeployProtocol.sol";
import {SetupProtocol, IRateOracle, VammConfiguration, Utils, AccessPassNFT} from "../../src/utils/SetupProtocol.sol";

import {ERC20Mock} from "../utils/ERC20Mock.sol";

import "./TestUtils.sol";
import {Merkle} from "murky/Merkle.sol";

import {UD60x18, ud60x18} from "@prb/math/UD60x18.sol";
import {SD59x18, sd59x18} from "@prb/math/SD59x18.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {SafeCastI256, SafeCastU256, SafeCastU128} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

contract ScenarioHelper is Test, SetupProtocol, TestUtils {
    using SetUtil for SetUtil.Bytes32Set;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;
    using SafeCastU128 for uint128;

    address owner = address(999999);
    ERC20Mock token = new ERC20Mock(6);
    DeployProtocol deployProtocol = new DeployProtocol(owner, address(token));
    SetUtil.Bytes32Set addressPassNftInfo;

    Merkle merkle = new Merkle();

    constructor() SetupProtocol(
        SetupProtocol.Contracts({
                coreProxy: deployProtocol.coreProxy(),
                datedIrsProxy: deployProtocol.datedIrsProxy(),
                peripheryProxy: deployProtocol.peripheryProxy(),
                vammProxy: deployProtocol.vammProxy(),
                aaveV3RateOracle: deployProtocol.aaveV3RateOracle(),
                aaveV3BorrowRateOracle: deployProtocol.aaveV3BorrowRateOracle()
            }),
            SetupProtocol.Settings({
                multisig: false,
                multisigAddress: address(0),
                multisigSend: false,
                echidna: false,
                broadcast: false,
                prank: true
            }),
            owner
    ){}

    function redeemAccessPass(address user, uint256 count, uint256 merkleIndex) public {
        metadata.accessPassNft.redeem(
            user,
            count,
            merkle.getProof(addressPassNftInfo.values(), merkleIndex),
            merkle.getRoot(addressPassNftInfo.values())
        );
    }

    function setUpAccessPassNft(address[] memory owners) public {
        for (uint256 i = 0; i < owners.length; i++) {
            addressPassNftInfo.add(keccak256(abi.encodePacked(owners[i], uint256(1))));
        }
        addNewRoot(
            AccessPassNFT.RootInfo({
                merkleRoot: merkle.getRoot(addressPassNftInfo.values()),
                baseMetadataURI: "ipfs://"
            })
        );
    }

    struct TakerExecutedAmounts {
        uint256 depositedAmount;
        int256 executedBaseAmount;
        int256 executedQuoteAmount;
        uint256 fee;
        uint256 im;
        // todo: add highestUnrealizedLoss
        // todo: can we pull more information to play with in tests?
    }

    struct MakerExecutedAmounts {
        int256 baseAmount;
        uint256 depositedAmount;
        int24 tickLower;
        int24 tickUpper;
        uint256 fee;
        uint256 im;
        // todo: add highestUnrealizedLoss
        // todo: can we pull more information to play with in tests?
    }

    function newMaker(
        uint128 _marketId,
        uint32 _maturityTimestamp,
        uint128 accountId,
        address user,
        uint256 count,
        uint256 merkleIndex,
        uint256 toDeposit,
        int256 baseAmount,
        int24 tickLower,
        int24 tickUpper
    ) public returns (MakerExecutedAmounts memory){
        changeSender(user);

        token.mint(user, toDeposit);
        redeemAccessPass(user, count, merkleIndex);

        // PERIPHERY LP COMMAND
        int256 liquidityIndex = UD60x18.unwrap(contracts.aaveV3RateOracle.getCurrentIndex()).toInt();

        bytes memory output = mintOrBurn(MintOrBurnParams({
            marketId: _marketId,
            tokenAddress: address(token),
            accountId: accountId,
            maturityTimestamp: _maturityTimestamp,
            marginAmount: toDeposit,
            notionalAmount: baseAmount * liquidityIndex / 1e18,
            tickLower: tickLower, // 4.67%
            tickUpper: tickUpper, // 2.35%
            rateOracleAddress: address(contracts.aaveV3RateOracle)
        }));

        (
            uint256 fee,
            uint256 im
        ) = abi.decode(output, (uint256, uint256));

        return MakerExecutedAmounts({
            baseAmount: baseAmount,
            depositedAmount: toDeposit,
            tickLower: tickLower,
            tickUpper: tickUpper,
            fee: fee,
            im: im
        });
    }

    function newTaker(
        uint128 _marketId,
        uint32 _maturityTimestamp,
        uint128 accountId,
        address user,
        uint256 count,
        uint256 merkleIndex,
        uint256 margin,
        int256 baseAmount
    ) public returns (TakerExecutedAmounts memory executedAmounts) {
        changeSender(user);

        // todo: if liquidation booster > 0, mint margin + liqBooster - liqBoosterBalance
        token.mint(user, margin);
        redeemAccessPass(user, count, merkleIndex);

        int256 liquidityIndex = UD60x18.unwrap(contracts.aaveV3RateOracle.getCurrentIndex()).toInt();

        bytes memory output = swap({
            marketId: _marketId,
            tokenAddress: address(token),
            accountId: accountId,
            maturityTimestamp: _maturityTimestamp,
            marginAmount: margin,
            notionalAmount: baseAmount * liquidityIndex,  // positive means VT, negative means FT
            rateOracleAddress: address(contracts.aaveV3RateOracle)
        });

        // todo: add unrealized loss to exposures
        (
            executedAmounts.executedBaseAmount,
            executedAmounts.executedQuoteAmount,
            executedAmounts.fee, 
            executedAmounts.im,,
        ) = abi.decode(output, (int256, int256, uint256, uint256, uint256, int24));

        executedAmounts.depositedAmount = margin;
    }

    struct MarginData {
        bool liquidatable;
        uint256 initialMarginRequirement;
        uint256 liquidationMarginRequirement;
        uint256 highestUnrealizedLoss;
    }

    struct UnfilledData {
        uint256 unfilledBaseLong;
        uint256 unfilledQuoteLong;
        uint256 unfilledBaseShort;
        uint256 unfilledQuoteShort;
    }

    // function checkImMaker(
    //     uint128 _marketId,
    //     uint32 _maturityTimestamp,
    //     uint128 accountId,
    //     address user,
    //     int256 _filledBase,
    //     MakerExecutedAmounts memory executedAmounts,
    //     uint256 twap
    // ) public returns (MarginData memory m, UnfilledData memory u){

    //     uint256 currentLiquidityIndex = UD60x18.unwrap(contracts.aaveV3RateOracle.getCurrentIndex());

    //     (
    //         m.liquidatable,
    //         m.initialMarginRequirement,
    //         m.liquidationMarginRequirement,
    //         m.highestUnrealizedLoss
    //     ) = contracts.coreProxy.isLiquidatable(accountId, address(token));

    //     // console2.log("liquidatable", m.liquidatable);
    //     // console2.log("initialMarginRequirement", m.initialMarginRequirement);
    //     // console2.log("liquidationMarginRequirement", m.liquidationMarginRequirement);
    //     // console2.log("highestUnrealizedLoss",m.highestUnrealizedLoss);

    //     (u.unfilledBaseLong, u.unfilledBaseShort, u.unfilledQuoteLong, u.unfilledQuoteShort) =
    //         contracts.vammProxy.getAccountUnfilledBaseAndQuote(_marketId, _maturityTimestamp, accountId);

    //     // console2.log("unfilledBaseLong", u.unfilledBaseLong);
    //     // console2.log("unfilledQuoteLong", u.unfilledQuoteLong);
    //     // console2.log("unfilledBaseShort", u.unfilledBaseShort);
    //     // console2.log("unfilledQuoteShort", u.unfilledQuoteShort);

    //     assertEq(uint256(executedAmounts.baseAmount), u.unfilledBaseLong+u.unfilledBaseShort + 1, "unfilledBase");
    //     assertEq(m.liquidatable, false, "liquidatable");
    //     assertGe(m.initialMarginRequirement, m.liquidationMarginRequirement, "lmr");

    //     // calculate LMRLow
    //     uint256 baseLower = absUtil(_filledBase - u.unfilledBaseShort.toInt());
    //     uint256 baseUpper = absUtil(_filledBase + u.unfilledBaseLong.toInt());
    //     // todo: replace 1 with protocolId
    //     uint256 riskParam = UD60x18.unwrap(contracts.coreProxy.getMarketRiskConfiguration(1, _marketId).riskParameter);
    //     uint256 expectedLmrLower = (riskParam * baseLower) * currentLiquidityIndex * timeFactor(_maturityTimestamp) / 1e54;
    //     uint256 expectedLmrUpper = (riskParam * baseUpper) * currentLiquidityIndex * timeFactor(_maturityTimestamp) / 1e54;

    //     // console2.log("baseLower", baseLower);
    //     // console2.log("baseUpper", baseUpper);
    //     // console2.log("expectedLmrLower", expectedLmrLower);
    //     // console2.log("expectedLmrUpper", expectedLmrUpper);

    //     // calculate unrealized loss low
    //     uint256 unrealizedLossLower = absOrZero(u.unfilledQuoteShort.toInt() - 
    //         (baseLower * currentLiquidityIndex * (twap * timeFactor(_maturityTimestamp) / 1e18 + 1e18) / 1e36).toInt());
    //     uint256 unrealizedLossUpper = absOrZero(-u.unfilledQuoteLong.toInt() + 
    //         (baseUpper * currentLiquidityIndex * (twap * timeFactor(_maturityTimestamp) / 1e18 + 1e18) / 1e36).toInt());
    //     // console2.log("unrealizedLossLower", unrealizedLossLower);
    //     // console2.log("unrealizedLossUpper", unrealizedLossUpper);

    //     // todo: manually calculate liquidation margin requirement for lower and upper scenarios and compare to the above
    //     uint256 expectedUnrealizedLoss = unrealizedLossUpper;
    //     uint256 expectedLmr = expectedLmrUpper;
    //     if (unrealizedLossLower + expectedLmrLower >  unrealizedLossUpper + expectedLmrUpper) {
    //         expectedUnrealizedLoss = unrealizedLossUpper;
    //         expectedLmr = expectedLmrUpper;
    //     }

    //     uint256 imMultiplier = UD60x18.unwrap(contracts.coreProxy.getProtocolRiskConfiguration().imMultiplier);
    //     assertEq(expectedUnrealizedLoss, m.highestUnrealizedLoss, "expectedUnrealizedLoss");
    //     assertAlmostEq(expectedLmr, m.liquidationMarginRequirement, 1e5);
    //     assertAlmostEq(expectedLmr * imMultiplier, m.initialMarginRequirement, 1e5);
    //     assertGt(executedAmounts.depositedAmount, expectedLmr * imMultiplier + expectedUnrealizedLoss, "IMR");
    // }

    // function checkImTaker(
    //     uint128 _marketId,
    //     uint32 _maturityTimestamp,
    //     uint128 accountId,
    //     address user,
    //     TakerExecutedAmounts memory executedAmounts,
    //     uint256 twap
    // ) public returns (MarginData memory m, UnfilledData memory u){

    //     uint256 currentLiquidityIndex = UD60x18.unwrap(contracts.aaveV3RateOracle.getCurrentIndex());

    //     (
    //         m.liquidatable,
    //         m.initialMarginRequirement,
    //         m.liquidationMarginRequirement,
    //         m.highestUnrealizedLoss
    //     ) = contracts.coreProxy.isLiquidatable(accountId, address(token));

    //     // console2.log("liquidatable", m.liquidatable);
    //     // console2.log("initialMarginRequirement", m.initialMarginRequirement);
    //     // console2.log("liquidationMarginRequirement", m.liquidationMarginRequirement);
    //     // console2.log("highestUnrealizedLoss",m.highestUnrealizedLoss);

    //     (u.unfilledBaseLong, u.unfilledBaseShort, u.unfilledQuoteLong, u.unfilledQuoteShort) =
    //         contracts.vammProxy.getAccountUnfilledBaseAndQuote(_marketId, _maturityTimestamp, accountId);

    //     assertEq(0, u.unfilledBaseLong);
    //     assertEq(0, u.unfilledQuoteLong);
    //     assertEq(0, u.unfilledBaseShort);
    //     assertEq(0, u.unfilledQuoteShort);

    //     // assertEq(m.liquidatable, false, "liquidatable");
    //     assertGe(m.initialMarginRequirement, m.liquidationMarginRequirement, "lmr");

    //     // calculate LMR
    //     // todo: replace 1 with protocolId
    //     uint256 riskParam = UD60x18.unwrap(contracts.coreProxy.getMarketRiskConfiguration(1, _marketId).riskParameter);
    //     uint256 expectedLmr = (riskParam * absUtil(executedAmounts.executedBaseAmount)) * currentLiquidityIndex * timeFactor(_maturityTimestamp) / 1e54;
    //     // console2.log("expectedLmr", expectedLmr);

    //     // calculate unrealized loss low
    //     uint256 expectedUnrealizedLoss = absOrZero(executedAmounts.executedQuoteAmount + 
    //         (executedAmounts.executedBaseAmount * currentLiquidityIndex.toInt() * (twap * timeFactor(_maturityTimestamp) / 1e18 + 1e18).toInt() / 1e36));

    //     // console2.log("expectedUnrealizedLoss", expectedUnrealizedLoss);
    //     uint256 imMultiplier = UD60x18.unwrap(contracts.coreProxy.getProtocolRiskConfiguration().imMultiplier);
    //     assertAlmostEq(expectedUnrealizedLoss.toInt(), m.highestUnrealizedLoss.toInt(), 1e5);
    //     assertAlmostEq(expectedLmr, m.liquidationMarginRequirement, 1e5);
    //     assertAlmostEq(expectedLmr * imMultiplier, m.initialMarginRequirement, 1e5);
    //     assertGt(executedAmounts.depositedAmount, expectedLmr * imMultiplier + expectedUnrealizedLoss, "IMR taker");
    // }

}