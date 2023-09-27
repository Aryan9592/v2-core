/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

library AutoExchangeConfiguration {

    /**
     * @notice Emitted when auto-exchange configuration is created or updated
     * @param config The object with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event AutoExchangeConfigurationUpdated(Data config, uint256 blockTimestamp);

    struct Data {
        /**
         * @dev Auto-exchange occurs when an account has a negative balance for one collateral asset in USD terms
         * is below the singleAutoExchangeThresholdInUSD (e.g. 5,000 USD)
         */
        uint256 singleAutoExchangeThresholdInUSD;

        /**
         * @dev Auto-exchange can also occur when the sum of all negative balances for an account in USD terms is
         * below the totalAutoExchangeThresholdInUSD (e.g. 10,000 USD)
         */
        uint256 totalAutoExchangeThresholdInUSD;

        /**
         * @dev Auto-exchange can also occur when the absolute value of the sum of all negative balances for an account
         * in USD terms is negativeCollateralBalancesMultiplier (e.g. 0.5) times larger than the total collateral
         * value in USD terms
         */
        UD60x18 negativeCollateralBalancesMultiplier;
    }

    /**
     * @dev Loads the AutoExchangeConfiguration object.
     * @return config The AutoExchangeConfiguration object.
     */
    function load() internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.AutoExchangeConfiguration"));
        assembly {
            config.slot := s
        }
    }

    /**
     * @dev Sets the protocol-wide auto-exchange configuration
     * @param config The AutoExchangeConfiguration object with all the auto-exchange parameters
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.singleAutoExchangeThresholdInUSD = config.singleAutoExchangeThresholdInUSD;
        storedConfig.totalAutoExchangeThresholdInUSD = config.totalAutoExchangeThresholdInUSD;
        storedConfig.negativeCollateralBalancesMultiplier = config.negativeCollateralBalancesMultiplier;

        emit AutoExchangeConfigurationUpdated(storedConfig, block.timestamp);
    }
}