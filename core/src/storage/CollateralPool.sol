/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;


/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {

    /**
     * @dev Thrown when a collateral pool cannot be found
     */
    error CollateralPoolNotFound(uint128 trustlessInstrumentId);


    /**
    * @dev Thrown when a collateral pool does not have sufficient collateral.
     */
    error InsufficientCollateralInCollateralPool(uint256 requestedAmount);

    // todo: consider introducing a CollateralPoolBalanceUpdate event similar to what we have in Collateral.sols (AN)

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
        * @dev Address set of collaterals alongside net balances that are held by the collateral pool
         */
        mapping(address => uint256) collateralBalances;

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
        collateralBalance = self.collateralBalances[collateralType];
    }

    /**
     * @dev Increments the collateral pool balance for a given collateral type
     */
    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        self.collateralBalances[collateralType] += amount;
    }

    /**
     * @dev Decrements the collateral pool balance for a given collateral type
     */
    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        if (self.collateralBalances[collateralType] < amount) {
            revert InsufficientCollateralInCollateralPool(amount);
        }

        self.collateralBalances[collateralType] -= amount;
    }

}