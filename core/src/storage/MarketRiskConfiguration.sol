/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Tracks market-level risk settings
 */
library MarketRiskConfiguration {
    struct Data {
        /**
         * @dev Id of the market for which we store risk configurations
         */
        uint128 marketId;
        /**
         * @dev Risk Parameters are multiplied by notional exposures to derived shocked cashflow calculations
         */
        UD60x18 riskParameter;
        /**
         * @dev Number of seconds in the past from which to calculate the time-weighted average fixed rate (average = geometric mean)
         */
        uint32 twapLookbackWindow;
    }

    /**
     * @dev Loads the MarketRiskConfiguration object for the given collateral type.
     * @param marketId Id of the market (e.g. aUSDC lend) for which we want to query the risk configuration
     * @return config The MarketRiskConfiguration object.
     */
    function load(uint128 marketId) internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.MarketRiskConfiguration", marketId));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Sets the risk configuration for a given marketId
     * @param config The RiskConfiguration object with all the risk parameters
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load(config.marketId);

        storedConfig.marketId = config.marketId;
        storedConfig.riskParameter = config.riskParameter;
        storedConfig.twapLookbackWindow = config.twapLookbackWindow;
    }
}
