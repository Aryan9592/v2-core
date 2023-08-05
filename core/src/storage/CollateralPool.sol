/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;

    /**
     * @dev Thrown when a collateral pool cannot be found
     */
    error CollateralPoolNotFound(uint128 id);

    /**
     * @dev Thrown when a collateral pool is already created
     */
    error CollateralPoolAlreadyExists(uint128 id);

    /**
     * @dev Thrown when a collateral pool does not have sufficient collateral.
     */
    error InsufficientCollateralInCollateralPool(uint256 requestedAmount);

    /**
     * @dev Thrown when an action is performed on a collateral pool that is already merged.
     */
    error InactiveCollateralPool(uint128 id);

    /**
     * @notice Emitted when the collateral pool is created or updated
     * @param id The id of the collateral pool.
     * @param rootId The id of the root collateral pool.
     */
    event CollateralPoolUpdated(uint128 id, uint128 rootId);
    
    /**
     * @notice Emitted when the collateral pool balance of some particular collateral type is updated.
     */
    event CollateralPoolBalanceUpdated(uint128 id, address collateralType, int256 tokenAmount);

    struct Data {
        /**
         * @dev Collateral pool Id
         */
        uint128 id;

        /**
        * @dev Address set of collaterals alongside net balances that are held by the collateral pool
         */
        mapping(address => uint256) collateralBalances;

        /**
         * @dev Root collateral pool ID
        */
        uint128 rootId;
    }

    /**
     * @dev Creates an collateral pool for the given id
     */
    function create(uint128 id) internal returns(Data storage collateralPool) {
        if (id == 0) {
            revert CollateralPoolAlreadyExists(id);
        }

        collateralPool = load(id);
        
        if (collateralPool.id > 0) {
            revert CollateralPoolAlreadyExists(id);
        }

        collateralPool.id = id;
        collateralPool.rootId = id;

        emit CollateralPoolUpdated(id, id);
    }

    function exists(uint128 id) internal view returns (Data storage collateralPool) {
        collateralPool = load(id);
    
        if (collateralPool.id == 0) {
            revert CollateralPoolNotFound(id);
        }
    }

    function checkRoot(Data storage self) internal view {
        if (self.id != self.rootId) {
            revert InactiveCollateralPool(self.id);
        }
    }

    /**
     * @dev Returns the root collateral pool of any collateral pool.
     */
    function getRoot(uint128 id) internal returns (Data storage collateralPool) {
        Data storage self = exists(id);
        Data storage root = self;

        while (root.rootId != root.id) {
            root = load(root.id);
        }

        self.rootId = root.id;
        emit CollateralPoolUpdated(self.id, self.rootId);

        return root;
    }

    /**
     * @dev Returns the root collateral pool of any collateral pool but it does not propagate.
     */
    function getRootWithoutPropagation(uint128 id) internal view returns (Data storage collateralPool) {
        Data storage root = exists(id);

        while (root.rootId != root.id) {
            root = load(root.id);
        }

        return root;
    }

    /**
     * @dev Returns the collateral pool stored at the specified id.
     */
    function load(uint128 id) internal pure returns (Data storage collateralPool) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.CollateralPool", id));
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
    returns (uint256)
    {
        self.checkRoot();
        return self.collateralBalances[collateralType];
    }

    /**
     * @dev Increments the collateral pool balance for a given collateral type
     */
    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        self.checkRoot();

        self.collateralBalances[collateralType] += amount;

        emit CollateralPoolBalanceUpdated(self.id, collateralType, amount.toInt());
    }

    /**
     * @dev Decrements the collateral pool balance for a given collateral type
     */
    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        self.checkRoot();

        if (self.collateralBalances[collateralType] < amount) {
            revert InsufficientCollateralInCollateralPool(amount);
        }

        self.collateralBalances[collateralType] -= amount;

        emit CollateralPoolBalanceUpdated(self.id, collateralType, -amount.toInt());
    }

}