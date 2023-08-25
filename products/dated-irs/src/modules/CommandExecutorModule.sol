/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/core/src/interfaces/external/ICommandExecutionModule.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import {InitiateTakerOrder} from "../libraries/actions/InitiateTakerOrder.sol";
import {InitiateMakerOrder} from "../libraries/actions/InitiateMakerOrder.sol";
import {Settlement} from "../libraries/actions/Settlement.sol";
import {MarketManagerConfiguration} from "../storage/MarketManagerConfiguration.sol";

/**
 * @title Module for executing Dated IRS commands
 * @dev See IMarketConfigurationModule.
 */
contract CommandExecutionModule is ICommandExecutionModule {

    error InvalidCommandType(uint256 commandType);
    error ExecutionNotAuthorized(address caller);

    bytes1 internal constant COMMAND_TYPE_MASK = 0x3f;
    // Command Types. Maximum supported command at this moment is 0x3f.
    uint256 constant V2_DATED_IRS_INSTRUMENT_SWAP = 0x00;
    uint256 constant V2_DATED_IRS_INSTRUMENT_SETTLE = 0x01;
    uint256 constant V2_DATED_IRS_EXCHANGE_LP = 0x02;
    uint256 constant V2_DATED_IRS_CLOSE_ACCOUNT = 0x03;

    /**
     * @inheritdoc ICommandExecutionModule
     */
    function executeCommand(
        uint128 accountId,
        bytes1 commandType,
        bytes calldata inputs
    ) external override returns (bytes memory output) {

        // only Core can call this function
        if (msg.sender != MarketManagerConfiguration.getCoreProxyAddress()) {
            revert ExecutionNotAuthorized(msg.sender);
        }

        uint256 command = uint8(commandType & COMMAND_TYPE_MASK);

        if (command == V2_DATED_IRS_INSTRUMENT_SWAP) {
            uint128 marketId;
            uint32 maturityTimestamp;
            int256 baseAmount;
            uint160 priceLimit;

            assembly {
                marketId := calldataload(inputs.offset)
                maturityTimestamp := calldataload(add(inputs.offset, 0x20))
                baseAmount := calldataload(add(inputs.offset, 0x40))
                priceLimit := calldataload(add(inputs.offset, 0x60))
            }
            (
                int256 executedBaseAmount,
                int256 executedQuoteAmount,
                uint256 fee
            ) = InitiateTakerOrder.initiateTakerOrder(
                InitiateTakerOrder.TakerOrderParams({
                    accountId: accountId,
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    baseAmount: baseAmount,
                    priceLimit: priceLimit
                })
            );
            output = abi.encode(executedBaseAmount, executedQuoteAmount, fee);
        } else if (command == V2_DATED_IRS_INSTRUMENT_SETTLE) {
            uint128 marketId;
            uint32 maturityTimestamp;
            assembly {
                marketId := calldataload(inputs.offset)
                maturityTimestamp := calldataload(add(inputs.offset, 0x20))
            }
            Settlement.settle(accountId, marketId, maturityTimestamp);
        } else if (command == V2_DATED_IRS_EXCHANGE_LP) {
            uint128 marketId;
            uint32 maturityTimestamp;
            int24 tickLower;
            int24 tickUpper;
            int128 liquidityDelta;
            assembly {
                marketId := calldataload(inputs.offset)
                maturityTimestamp := calldataload(add(inputs.offset, 0x20))
                tickLower := calldataload(add(inputs.offset, 0x40))
                tickUpper := calldataload(add(inputs.offset, 0x60))
                liquidityDelta := calldataload(add(inputs.offset, 0x80))
            }
            uint256 fee = InitiateMakerOrder.initiateMakerOrder(
                InitiateMakerOrder.MakerOrderParams({
                    accountId: accountId,
                    marketId: marketId,
                    maturityTimestamp: maturityTimestamp,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: liquidityDelta
                })
            );
            output = abi.encode(fee);
        } else {
            revert InvalidCommandType(command);
        }
    }

}
