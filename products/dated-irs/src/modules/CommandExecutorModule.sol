/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/core/src/interfaces/external/ICommandExecutorModule.sol";
import "@voltz-protocol/core/src/interfaces/external/IVoltzContract.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import "../interfaces/IMarketManagerIRSModule.sol";

/**
 * @title Module for executing Dated IRS commands
 * @dev See IMarketConfigurationModule.
 */
contract CommandExecutorModule is ICommandExecutorModule, IVoltzContract {

    error InvalidCommandType(uint256 commandType);

    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;
    // Command Types. Maximum supported command at this moment is 0x3f.
    uint256 constant V2_DATED_IRS_INSTRUMENT_SWAP = 0x00;
    uint256 constant V2_DATED_IRS_INSTRUMENT_SETTLE = 0x01;
    uint256 constant V2_VAMM_EXCHANGE_LP = 0x02;

    /**
     * @inheritdoc ICommandExecutorModule
     */
    function executeCommand(
        uint128 affectedAccountId,
        bytes1 commandType,
        bytes calldata inputs
    ) external override returns (bytes memory output) {
        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

        if (command == V2_DATED_IRS_INSTRUMENT_SWAP) {
            // equivalent: abi.decode(inputs, (uint128, uint128, uint32, int256, uint160))
            uint128 accountId;
            uint128 marketId;
            uint32 maturityTimestamp;
            int256 baseAmount;
            uint160 priceLimit;

            assembly {
                accountId := calldataload(inputs.offset)
                marketId := calldataload(add(inputs.offset, 0x20))
                maturityTimestamp := calldataload(add(inputs.offset, 0x40))
                baseAmount := calldataload(add(inputs.offset, 0x60))
                priceLimit := calldataload(add(inputs.offset, 0x80))
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            (
                int256 executedBaseAmount,
                int256 executedQuoteAmount,
                uint256 fee,
                Account.MarginRequirement memory mr
            ) = IMarketManagerIRSModule(address(this)).initiateTakerOrder(
                IMarketManagerIRSModule.TakerOrderParams({
                    accountId: accountId,
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    baseAmount: baseAmount,
                    priceLimit: priceLimit
                })
            );
            output = abi.encode(executedBaseAmount, executedQuoteAmount, fee, mr);
        } else if (command == V2_DATED_IRS_INSTRUMENT_SETTLE) {
            // equivalent: abi.decode(inputs, (uint128, uint128, uint32))
            uint128 accountId;
            uint128 marketId;
            uint32 maturityTimestamp;
            assembly {
                accountId := calldataload(inputs.offset)
                marketId := calldataload(add(inputs.offset, 0x20))
                maturityTimestamp := calldataload(add(inputs.offset, 0x40))
            }
            require(accountId == affectedAccountId, "AccountId missmatch");
            IMarketManagerIRSModule(address(this)).settle(accountId, marketId, maturityTimestamp);
        } else if (command == V2_VAMM_EXCHANGE_LP) {
            // equivalent: abi.decode(inputs, (uint128, uint128, uint32, int24, int24, int128))
            uint128 accountId;
            uint128 marketId;
            uint32 maturityTimestamp;
            int24 tickLower;
            int24 tickUpper;
            int128 liquidityDelta;
            assembly {
                accountId := calldataload(inputs.offset)
                marketId := calldataload(add(inputs.offset, 0x20))
                maturityTimestamp := calldataload(add(inputs.offset, 0x40))
                tickLower := calldataload(add(inputs.offset, 0x60))
                tickUpper := calldataload(add(inputs.offset, 0x80))
                liquidityDelta := calldataload(add(inputs.offset, 0xA0))
            }
            (uint256 fee, Account.MarginRequirement memory mr) = IMarketManagerIRSModule(address(this)).initiateMakerOrder(
                IMarketManagerIRSModule.MakerOrderParams({
                    accountId: accountId,
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta
                })
            );
            output = abi.encode(fee, mr);
        } else {
            revert InvalidCommandType(command);
        }
    }

    /**
     * @inheritdoc IVoltzContract
     */
    function isVoltzContract() external pure override returns (bool) {
        return true;
    }

}
