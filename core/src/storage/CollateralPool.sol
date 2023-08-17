/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import {UD60x18} from "@prb/math/UD60x18.sol";

import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "./Account.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {
    using CollateralPool for CollateralPool.Data;
    using SafeCastU256 for uint256;
    using SetUtil for SetUtil.AddressSet;

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
     * @dev Thrown when a merge proposal is initiated between one pool and itself.
     */
    error CannotMergePoolWithItself(uint128 id);

    /**
     * @dev Thrown when an action is performed on a collateral pool that is already merged.
     */
    error InactiveCollateralPool(uint128 id);

    /**
     * @dev Thrown when parent tries to accept non-existent or revoked merge proposal.
     */
    error UninitiatedMergeProposal(uint128 childId, uint128 actualProposedParentId, uint128 parentId);

    /**
     * @dev Thrown when some address tries to act as the owner of the collateral pool.
     */
    error Unauthorized(address owner);

    /**
     * @notice Emitted when the collateral pool is created or updated
     */
    event CollateralPoolUpdated(
        uint128 id,
        uint128 rootId,
        RiskConfiguration riskConfig,
        InsuranceFundConfig insuranceFundConfig,
        uint256 blockTimestamp
    );
    
    /**
     * @notice Emitted when the collateral pool balance of some particular collateral type is updated.
     */
    event CollateralPoolBalanceUpdated(uint128 id, address collateralType, int256 tokenAmount, uint256 blockTimestamp);

    struct RiskConfiguration {
        /**
         * @dev IM Multiplier is used to introduce a buffer between the liquidation (LM) and initial (IM) margin requirements
         * where IM = imMultiplier * LM
         */
        UD60x18 imMultiplier;
        /**
         * @dev Liquidator reward parameters are multiplied by the im delta caused by the liquidation to get the liquidator reward
         * amount
         */
        UD60x18 liquidatorRewardParameter;
    }

    struct InsuranceFundConfig {
        /**
         * @dev Pool's insurance fund account ID
         */
        uint128 accountId;
        /**
         * @dev Percentage of the collateral pool maker and taker fees that 
         * @dev go towards the insurance fund. (e.g. 0.1 * 1e18 = 10%)
         */
        UD60x18 makerAndTakerFee;
        /**
         * @dev Percentage of quote tokens paid to the insurance fund 
         * @dev at auto-exchange. (e.g. 0.1 * 1e18 = 10%)
         */
        UD60x18 autoExchangeFee;
    }

    struct Data {
        /**
         * @dev Collateral pool Id
         */
        uint128 id;
        /**
         * @dev Owner of the collateral pool, which has configuration access rights 
         * for the collateral pool and underlying markets configuration.
         */
        address owner;
        /**
         * @dev Address set of collaterals alongside net balances that are held by the collateral pool
         */
        mapping(address => uint256) collateralBalances;
        /**
         * @dev Addresses of all collateral types in which the collateral pool has a non-zero balance
         */
        SetUtil.AddressSet activeCollaterals;
        /**
         * @dev Root collateral pool ID
         */
        uint128 rootId;
        /**
         * @dev Collateral pool wide risk configuration 
         */
        RiskConfiguration riskConfig;
        /**
         * @dev If proposed parent id is greater than 0, then the collateral pool awaits for approval from parent owner to merge. 
         */
        uint128 proposedParentId;
        /**
         * @dev Collateral pool wide insurance fund configuration 
         */
        InsuranceFundConfig insuranceFundConfig;
    }

    /**
     * @dev Creates an collateral pool for the given id
     */
    function create(uint128 id, address owner) internal returns(Data storage collateralPool) {
        if (id == 0) {
            revert CollateralPoolAlreadyExists(id);
        }

        collateralPool = load(id);
        
        if (collateralPool.id != 0) {
            revert CollateralPoolAlreadyExists(id);
        }

        collateralPool.id = id;
        collateralPool.owner = owner;
        collateralPool.rootId = id;

        emit CollateralPoolUpdated(id, id, collateralPool.riskConfig, collateralPool.insuranceFundConfig, block.timestamp);
    }

    function exists(uint128 id) internal view returns (Data storage collateralPool) {
        collateralPool = load(id);
    
        if (collateralPool.id == 0) {
            revert CollateralPoolNotFound(id);
        }
    }

    function initiateMergeProposal(Data storage self, uint128 parentId) internal {
        if (self.id == parentId) {
            revert CannotMergePoolWithItself(self.id);
        }

        self.proposedParentId = parentId;
    }

    function acceptMergeProposal(Data storage self, uint128 childId) internal {
        CollateralPool.Data storage child = exists(childId);

        if (child.proposedParentId != self.id) {
            revert UninitiatedMergeProposal(self.id, child.proposedParentId, childId);
        }
        
        self.merge(child);
    }

    function revokeMergeProposal(Data storage self) internal {
        self.proposedParentId = 0;
    }

    function merge(Data storage parent, Data storage child) internal {
        parent.checkRoot();
        child.checkRoot();

        for (uint256 i = 1; i <= child.activeCollaterals.length(); i++) {
            address activeCollateral = child.activeCollaterals.valueAt(i);

            parent.increaseCollateralBalance(activeCollateral, child.collateralBalances[activeCollateral]);
        }

        child.rootId = parent.id;

        emit CollateralPoolUpdated(child.id, child.rootId, child.riskConfig, child.insuranceFundConfig,  block.timestamp);
    }

    function checkRoot(Data storage self) internal view {
        if (self.id != self.rootId) {
            revert InactiveCollateralPool(self.id);
        }
    }

    /**
     * @dev Returns the root collateral pool of any collateral pool.
     */
    function getRoot(uint128 id) internal view returns (Data storage collateralPool) {
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

        // add the collateral type to the active collaterals if missing
        if (self.collateralBalances[collateralType] > 0) {
            if (!self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.add(collateralType);
            }
        }

        emit CollateralPoolBalanceUpdated(self.id, collateralType, amount.toInt(), block.timestamp);
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

        // remove the collateral type from the active collaterals if balance goes to zero
        if (self.collateralBalances[collateralType] == 0) {
            if (self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.remove(collateralType);
            }
        }

        emit CollateralPoolBalanceUpdated(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    /**
     * @dev Set the collateral pool wide risk configuration
     * @param config The ProtocolRiskConfiguration object with all the protocol-wide risk parameters
     */
    function setRiskConfiguration(Data storage self, RiskConfiguration memory config) internal {
        self.checkRoot();

        self.riskConfig.imMultiplier = config.imMultiplier;
        self.riskConfig.liquidatorRewardParameter = config.liquidatorRewardParameter;

        emit CollateralPoolUpdated(self.id, self.rootId, self.riskConfig, self.insuranceFundConfig, block.timestamp);
    }

    /**
     * @dev Set the collateral pool wide insurance fund configuration
     * @param config The InsuranceFundConfig object with the account id and fee config
     */
    function setInsuranceFundConfig(Data storage self, InsuranceFundConfig memory config) internal {
        self.checkRoot();

        // create account if none
        if (self.insuranceFundConfig.accountId == 0) {
            Account.create(config.accountId, self.owner, Account.MULTI_TOKEN_MODE);
        }

        self.insuranceFundConfig.accountId = config.accountId;
        self.insuranceFundConfig.makerAndTakerFee = config.makerAndTakerFee;
        self.insuranceFundConfig.autoExchangeFee = config.autoExchangeFee;

        emit CollateralPoolUpdated(self.id, self.rootId, self.riskConfig, self.insuranceFundConfig, block.timestamp);
    }

    function onlyOwner(Data storage self) internal view {
        if (msg.sender != self.owner) {
            revert Unauthorized(msg.sender);
        }
    }
}