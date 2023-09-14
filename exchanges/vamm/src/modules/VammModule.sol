// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IVammModule} from "../interfaces/IVammModule.sol";
import {DatedIrsVamm} from "../storage/DatedIrsVamm.sol";
import {LPPosition} from "../storage/LPPosition.sol";
import {Oracle} from "../storage/Oracle.sol";
import {Tick} from "../libraries/ticks/Tick.sol";
import {Twap} from "../libraries/vamm-utils/Twap.sol";

import {OwnableStorage} from "@voltz-protocol/util-contracts/src/storage/OwnableStorage.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Module for configuring a market
 * @dev See IMarketConfigurationModule.
 */
contract VammModule is IVammModule {
    using DatedIrsVamm for DatedIrsVamm.Data;
    using SetUtil for SetUtil.UintSet;
    using SafeCastU256 for uint256;

    /**
     * @inheritdoc IVammModule
     */
    function createVamm(
        uint160 sqrtPriceX96, 
        uint32[] calldata times, 
        int24[] calldata observedTicks, 
        DatedIrsVamm.Immutable calldata config, 
        DatedIrsVamm.Mutable calldata mutableConfig
    ) external override {
        OwnableStorage.onlyOwner();
    
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.create(
            sqrtPriceX96,
            times,
            observedTicks,
            config,
            mutableConfig
        );
    
        emit VammCreated(
            vamm.vars.tick,
            config,
            mutableConfig,
            block.timestamp
        );
    }

    /**
     * @inheritdoc IVammModule
     */
    function configureVamm(uint128 marketId, uint32 maturityTimestamp, DatedIrsVamm.Mutable calldata config)
    external override
    {
        OwnableStorage.onlyOwner();
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        vamm.configure(config);
        emit VammConfigUpdated(marketId, maturityTimestamp, config, block.timestamp);
    }

    /**
      * @inheritdoc IVammModule
      */
    function increaseObservationCardinalityNext(uint128 marketId, uint32 maturityTimestamp, uint16 observationCardinalityNext)
    external override
    {
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        Twap.increaseObservationCardinalityNext(vamm, observationCardinalityNext);
    }

    ////////// GETTERS //////////

    function getVammConfig(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (
        DatedIrsVamm.Immutable memory config,
        DatedIrsVamm.Mutable memory mutableConfig
    ) {
         DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
         config = vamm.immutableConfig;
         mutableConfig = vamm.mutableConfig;
    }

    function getVammSqrtPriceX96(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (uint160) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.sqrtPriceX96;
    }

    function getVammTick(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (int24) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.tick;
    }

    function getVammTickInfo(uint128 marketId, uint32 maturityTimestamp, int24 tick)
        external view override returns (Tick.Info memory) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.ticks[tick];
    }

    function getVammTickBitmap(uint128 marketId, uint32 maturityTimestamp, int16 wordPosition)
        external view override returns (uint256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.tickBitmap[wordPosition];
    }
    
    function getVammLiquidity(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (uint128) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.liquidity;
    }

    function getVammPositionsInAccount(uint128 marketId, uint32 maturityTimestamp, uint128 accountId)
        external view override returns (uint128[] memory positionIds) {

        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        uint256[] memory positions = vamm.vars.accountPositions[accountId].values();

        positionIds = new uint128[](positions.length);
        for (uint256 i = 0; i < positions.length; i++) {
            positionIds[i] = positions[i].to128();
        }

        return positionIds;
    }

    function getVammPosition(uint128 positionId)
        external view override returns (LPPosition.Data memory) {

        LPPosition.Data storage position = LPPosition.exists(positionId);
        return position;
    }

    function getVammTrackerQuoteTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (int256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.trackerQuoteTokenGrowthGlobalX128;
    }
    
    function getVammTrackerBaseTokenGrowthGlobalX128(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (int256) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.trackerBaseTokenGrowthGlobalX128;
    }

    function getVammObservationInfo(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (uint16, uint16, uint16) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return (vamm.vars.observationIndex, vamm.vars.observationCardinality, vamm.vars.observationCardinalityNext);
    }

    function getVammObservationAtIndex(uint16 index, uint128 marketId, uint32 maturityTimestamp)
        external view override returns (Oracle.Observation memory) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observations[index];
    }

    function getVammObservations(uint128 marketId, uint32 maturityTimestamp)
        external view override returns (Oracle.Observation[65535] memory) {
        
        DatedIrsVamm.Data storage vamm = DatedIrsVamm.loadByMaturityAndMarket(marketId, maturityTimestamp);
        return vamm.vars.observations;
    }
}
