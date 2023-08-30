/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import {Account} from "./Account.sol";
import {CollateralConfiguration} from "./CollateralConfiguration.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";
import {TokenTypeSupport} from "../libraries/TokenTypeSupport.sol";

import {UD60x18} from "@prb/math/UD60x18.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {FeatureFlag} from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {
    using CollateralPool for CollateralPool.Data;
    using FeatureFlag for FeatureFlag.Data;
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
     * @notice Thrown on deposit when the collateral cap would have been exceeded
     * @param collateralPoolId The ID of the collateral pool
     * @param collateralType The address of the collateral of the unsuccessful deposit
     * @param collateralCap The cap limit of the collateral
     * @param poolBalance The exceeding balance of the collateral pool in that specific collateral
     */
    error CollateralCapExceeded(
        uint128 collateralPoolId,
        address collateralType,
        uint256 collateralCap,
        uint256 poolBalance
    );

    /**
     * @notice Emitted when the collateral pool is created or updated
     */
    event CollateralPoolUpdated(
        uint128 id,
        uint128 rootId,
        RiskConfiguration riskConfig,
        InsuranceFundConfig insuranceFundConfig,
        uint128 feeCollectorAccountId,
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
        mapping(address => uint256) collateralShares;
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
        /**
         * @dev Account id for the collector of protocol fees
         */
        uint128 feeCollectorAccountId;
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
        collateralPool.rootId = id;
        setOwner(collateralPool, owner);

        emit CollateralPoolUpdated(
            id,
            id,
            collateralPool.riskConfig,
            collateralPool.insuranceFundConfig,
            collateralPool.feeCollectorAccountId,
            block.timestamp
        );
    }

    function setOwner(Data storage self, address owner) private {
        self.owner = owner;

        FeatureFlag.load(
            FeatureFlagSupport.getCollateralPoolEnabledFeatureFlagId(self.id)
        ).setOwner(owner);
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

        address[] memory activeCollaterals = child.activeCollaterals.values();

        for (uint256 i = 0; i < activeCollaterals.length; i++) {
            address activeCollateral = activeCollaterals[i];

            CollateralConfiguration.Data storage collateral = CollateralConfiguration.exists(parent.id, activeCollateral);

            increaseCollateralShares(parent, collateral, child.collateralShares[activeCollateral]);
        }

        child.rootId = parent.id;

        emit CollateralPoolUpdated(
            child.id,
            child.rootId,
            child.riskConfig,
            child.insuranceFundConfig,
            child.feeCollectorAccountId,
            block.timestamp
        );
    }

    function isRoot(Data storage self) internal view returns(bool) {
        return self.id == self.rootId;
    }

    function checkRoot(Data storage self) internal view {
        if (!self.isRoot()) {
            revert InactiveCollateralPool(self.id);
        }
    }

    /**
     * @dev Returns the root collateral pool of any collateral pool.
     */
    function getRoot(uint128 id) internal view returns (Data storage collateralPool) {
        Data storage root = exists(id);

        while (root.rootId != root.id) {
            root = exists(root.id);
        }

        return root;
    }

    /**
     * @dev Returns the collateral pool stored at the specified id.
     */
    function load(uint128 id) private pure returns (Data storage collateralPool) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.CollateralPool", id));
        assembly {
            collateralPool.slot := s
        }
    }

    function checkCap(Data storage self, CollateralConfiguration.Data storage collateral)
        private 
        view 
    {
        // Check that this deposit does not reach the cap
        uint256 collateralCap = collateral.baseConfig.cap;

        // Get the address of the collateral
        address collateralAddress = collateral.cachedConfig.tokenAddress;

        // If the cap is maximum, bypass this check to avoid fetching the collateral balance
        if (collateralCap == type(uint256).max) {
            return;
        }

        // Fetch the collateral balance
        uint256 collateralBalance = self.getCollateralBalance(collateral);

        // Check the cap
        if (collateralBalance < collateralCap) {
            revert CollateralCapExceeded(self.id, collateralAddress, collateralCap, collateralBalance);
        }
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the collateral pool
     */
    function getCollateralBalance(
        Data storage self,
        CollateralConfiguration.Data storage collateral
    ) 
        internal
        view
        returns(uint256) 
    {
        if (!self.isRoot()) {
            return 0;
        }

        address collateralAddress = collateral.cachedConfig.tokenAddress;
        bytes32 collateralType = collateral.baseConfig.tokenType;

        return TokenTypeSupport.convertToAssets(
            collateralAddress, 
            collateralType, 
            self.collateralShares[collateralAddress]
        );
    }

    function increaseCollateralShares(
        Data storage self,
        CollateralConfiguration.Data storage collateral, 
        uint256 shares
    ) internal {
        address collateralAddress = collateral.cachedConfig.tokenAddress;
        
        // Increase the collateral shares
        self.collateralShares[collateralAddress] += shares;

        // Add the collateral type to the active collaterals if missing
        if (self.collateralShares[collateralAddress] > 0) {
            if (!self.activeCollaterals.contains(collateralAddress)) {
                self.activeCollaterals.add(collateralAddress);
            }
        }

        // Check that this deposit does not reach the cap
        checkCap(self, collateral);

        emit CollateralPoolBalanceUpdated(self.id, collateralAddress, shares.toInt(), block.timestamp);
    }

    function decreaseCollateralShares(
        Data storage self, 
        CollateralConfiguration.Data storage collateral, 
        uint256 shares
    ) internal {
        address collateralAddress = collateral.cachedConfig.tokenAddress;

        if (self.collateralShares[collateralAddress] < shares) {
            revert InsufficientCollateralInCollateralPool(shares);
        }

        self.collateralShares[collateralAddress] -= shares;

        // remove the collateral type from the active collaterals if balance goes to zero
        if (self.collateralShares[collateralAddress] == 0) {
            if (self.activeCollaterals.contains(collateralAddress)) {
                self.activeCollaterals.remove(collateralAddress);
            }
        }

        emit CollateralPoolBalanceUpdated(self.id, collateralAddress, -shares.toInt(), block.timestamp);
    }

    /**
     * @dev Set the collateral pool wide risk configuration
     * @param config The ProtocolRiskConfiguration object with all the protocol-wide risk parameters
     */
    function setRiskConfiguration(Data storage self, RiskConfiguration memory config) internal {
        self.checkRoot();

        self.riskConfig.imMultiplier = config.imMultiplier;
        self.riskConfig.liquidatorRewardParameter = config.liquidatorRewardParameter;

        emit CollateralPoolUpdated(
            self.id, 
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.feeCollectorAccountId,
            block.timestamp
        );
    }

    /**
     * @dev Set the collateral pool wide insurance fund configuration
     * @param config The InsuranceFundConfig object with the account id and fee config
     */
    function setInsuranceFundConfig(Data storage self, InsuranceFundConfig memory config) internal {
        self.checkRoot();

        // ensure the given account exists
        Account.exists(config.accountId);

        self.insuranceFundConfig.accountId = config.accountId;
        self.insuranceFundConfig.autoExchangeFee = config.autoExchangeFee;

        emit CollateralPoolUpdated(
            self.id,
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.feeCollectorAccountId,
            block.timestamp
        );
    }

    function setFeeCollectorAccountId(Data storage self, uint128 accountId) internal {
        self.checkRoot();

        // ensure the given account exists
        Account.exists(accountId);

        self.feeCollectorAccountId = accountId;

        emit CollateralPoolUpdated(
            self.id,
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.feeCollectorAccountId,
            block.timestamp
        );
    }

    function onlyOwner(Data storage self) internal view {
        if (msg.sender != self.owner) {
            revert Unauthorized(msg.sender);
        }
    }
}