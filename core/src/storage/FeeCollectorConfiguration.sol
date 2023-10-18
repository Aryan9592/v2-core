/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./Account.sol";

library FeeCollectorConfiguration {

    /**
     * @dev Thrown when fee collector configuration is not found
     */
    error FeeCollectorConfigNotFound();

    struct Data {
        /**
         * @dev Account id for the collector of protocol fees
         */
        uint128 feeCollectorAccountId;
    }

    /**
     * @dev Returns fee collector configuration object
     */
    function load() private pure returns (Data storage feeCollectorConfiguration) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.FeeCollectorConfiguration"));
        assembly {
            feeCollectorConfiguration.slot := s
        }
    }

    function loadAccount() internal view returns (Account.Data storage account) {
        Data storage feeCollectorConfig = load();
        account = Account.exists(feeCollectorConfig.feeCollectorAccountId);
        return account;
    }

    function exists() internal view returns (Data storage feeCollectorConfiguration) {
        feeCollectorConfiguration = load();

        if (feeCollectorConfiguration.feeCollectorAccountId == 0) {
            revert FeeCollectorConfigNotFound();
        }
    }

    function setFeeCollectorAccountId(uint128 feeCollectorAccountId) internal returns (Data storage feeCollectorConfiguration) {
        feeCollectorConfiguration = load();
        feeCollectorConfiguration.feeCollectorAccountId = feeCollectorAccountId;
        // todo: emit event
    }


}