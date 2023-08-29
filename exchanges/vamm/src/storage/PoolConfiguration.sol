// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracle.sol";
import "@voltz-protocol/products-dated-irs/src/interfaces/IRateOracleModule.sol";

/// @title Pool configuration
library PoolConfiguration {
    event PauseState(bool newPauseState, uint256 blockTimestamp);

    struct Data {
        bool paused;
        address marketManagerAddress;
        uint256 makerPositionsPerAccountLimit;
    }

    function load() internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.PoolConfiguration"));
        assembly {
            config.slot := s
        }
    }

    function setPauseState(Data storage self, bool state) internal {
        self.paused = state;
        emit PauseState(state, block.timestamp);
    }

    function setMarketManagerAddress(Data storage self, address _marketManagerAddress) internal {
        self.marketManagerAddress = _marketManagerAddress;
    }

    function setMakerPositionsPerAccountLimit(Data storage self, uint256 limit) internal {
        self.makerPositionsPerAccountLimit = limit;
    }

    function whenNotPaused() internal view {
        require(!PoolConfiguration.load().paused, "Paused");
    }

    function getRateOracle(uint128 marketId) internal view returns (IRateOracle) {
        address rateOracleAddress = IRateOracleModule(load().marketManagerAddress)
            .getRateOracleConfiguration(marketId).oracleAddress;
        return IRateOracle(rateOracleAddress);
    }
}
