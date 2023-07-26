/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

// todo: make sure it is safe to reuse Collateral.sol library (mainly thinking about storage collisions)
import "./Collateral.sol";


/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {

    /**
     * @dev Thrown when a collateral pool cannot be found
     */
    error CollateralPoolNotFound(uint128 trustlessInstrumentId);

    struct Data {

        /**
         * @dev Each trustless instrument has a unique collateral pool of assets associated with it
         * @dev If the trustlessInstrumentId == type(uint128).max -> identifies the collateral pool
         * shared across all the trusted instruments registered with the system
         */
        uint128 trustlessInstrumentId;

        /**
         * @dev Flag to check if the collateral pool has been initialized
        */

        bool isInitialized;

        /**
        * @dev Address set of collaterals that are being used in the protocols by this collateral pool
         */
        mapping(address => Collateral.Data) collaterals;

    }

    /**
     * @dev Creates an collateral pool for the given trustlessInstrumentId
     *
     * Note: Will not fail if the collateral pool already exists,
     *  Whatever calls this internal function must first check that the collateral pool doesn't exist before re-creating it.
     */
    function create(uint128 trustlessInstrumentId) internal returns(Data storage collateralPool) {
        collateralPool = load(trustlessInstrumentId);
        collateralPool.trustlessInstrumentId = trustlessInstrumentId;
        collateralPool.isInitialized = true;
    }

    function exists(uint128 trustlessInstrumentId) internal view returns (Data storage collateralPool) {
        Data storage c = load(trustlessInstrumentId);
        if (!c.isInitialized) {
            revert CollateralPoolNotFound(trustlessInstrumentId);
        }
        return c;
    }

    /**
    * @dev Returns the account stored at the specified account id.
     */
    function load(uint128 trustlessInstrumentId) internal pure returns (Data storage collateralPool) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.CollateralPool", trustlessInstrumentId));
        assembly {
            collateralPool.slot := s
        }
    }

    /**
    * @dev Given a collateral type, returns information about the collateral balance of the collateral pool
     */
    function getCollateralBalance(Data storage self, address collateralType)
    internal
    view
    returns (uint256 collateralBalance)
    {
        collateralBalance = self.collaterals[collateralType].balance;
    }

}