// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "../interfaces/external/IWETH9.sol";

/**
 * @title Config
 */
library Config {
    struct Data {
        IWETH9 WETH9;
        address VOLTZ_V2_CORE_PROXY;
        address VOLTZ_V2_DATED_IRS_PROXY;
        address VOLTZ_V2_DATED_IRS_VAMM_PROXY;
        // todo: note, transfer is no longer necessary, consider removing VOLTZ_V2_ACCOUNT_NFT_PROXY from the config
        address VOLTZ_V2_ACCOUNT_NFT_PROXY;
    }

    /**
     * @dev Configures the periphery
     * @param config The Config object with all the settings for the Periphery
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load();
        storedConfig.WETH9 = config.WETH9;
        storedConfig.VOLTZ_V2_CORE_PROXY = config.VOLTZ_V2_CORE_PROXY;
        storedConfig.VOLTZ_V2_DATED_IRS_PROXY = config.VOLTZ_V2_DATED_IRS_PROXY;
        storedConfig.VOLTZ_V2_DATED_IRS_VAMM_PROXY = config.VOLTZ_V2_DATED_IRS_VAMM_PROXY;
        storedConfig.VOLTZ_V2_ACCOUNT_NFT_PROXY = config.VOLTZ_V2_ACCOUNT_NFT_PROXY;
    }

    /**
     * @dev Loads the periphery configuration
     * @return config The periphery configuration object.
     */
    function load() internal pure returns (Data storage config) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.PeripheryConfiguration"));
        assembly {
            config.slot := s
        }
    }
}
