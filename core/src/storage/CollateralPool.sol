/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import {Account} from "./Account.sol";
import {CollateralConfiguration} from "./CollateralConfiguration.sol";
import {GlobalCollateralConfiguration} from "./GlobalCollateralConfiguration.sol";
import {FeatureFlagSupport} from "../libraries/FeatureFlagSupport.sol";

import {UD60x18} from "@prb/math/UD60x18.sol";
import {SD59x18} from "@prb/math/SD59x18.sol";
import {SafeCastU256, SafeCastI256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {FeatureFlag} from "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library CollateralPool {
    using CollateralPool for CollateralPool.Data;
    using FeatureFlag for FeatureFlag.Data;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using SetUtil for SetUtil.AddressSet;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using GlobalCollateralConfiguration for GlobalCollateralConfiguration.Data;

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
        BackstopLPConfig backstopLPConfig,
        uint128 feeCollectorAccountId,
        uint256 blockTimestamp
    );
    
    /**
     * @notice Emitted when the collateral pool balance of some particular collateral type is updated.
     */
    event CollateralPoolBalanceUpdated(uint128 id, address collateralType, int256 tokenAmount, uint256 blockTimestamp);

    struct RiskMultipliers {

        /**
         * @dev IM Multiplier is used to introduce a buffer between the liquidation (LM) and initial (IM) margin requirements
         * where IM = imMultiplier * LM
         */
        UD60x18 imMultiplier;

        /**
         * @dev MMR Multiplier (maintenance margin requirement multiplier)
         * is used to introduce a buffer before liquidations occur to allow for liquidation bid submissions
         * where MMR = mmrMultiplier * LM
         */
        UD60x18 mmrMultiplier;


        /**
         * @dev Dutch Multiplier (dutch margin requirement multiplier)
         * is used to determine when dutch liquidations can kick off (if liquidation bids take too long to execute)
         * where dutch margin requirement = dutchMultiplier * LM
         */
        UD60x18 dutchMultiplier;


        /**
         * @dev ADL Multiplier (auto-deleveraging margin requirement multiplier)
         * is used to determine when adl & backstop lps can jump in to remove risk from the system
         * where adl margin requirement = adlMultiplier * LM
         */
        UD60x18 adlMultiplier;

    }

    struct LiquidationConfiguration {
        /**
       * @dev Parameter that's multiplied by the change in LM caused by triggering closure of unfilled orders
         */
        UD60x18 unfilledPenaltyParameter;

        /**
         * @dev Fee percentage charged by the keepers that execute liquidation bids
         */
        UD60x18 bidKeeperFee;

        /**
         * @dev Liquidation Bid Priority Queue Duration In Seconds
         */
        uint256 queueDurationInSeconds;

        /**
         * @dev Maximum number of orders that a liquidation bid can contain
         */
        uint256 maxOrdersInBid;

        /**
         * @dev Maximum number of liquidations bids that can be submitted to a single liquidation bid priority queue
         */
        uint256 maxBidsInQueue;
    }

    struct DutchConfiguration {
        /**
         * @dev Minimum reward parameter
         */
        UD60x18 dMin;
        /**
         * @dev The percentage point change of the liquidator reward following a percentage point 
         * change in the health of the liquidatable account
         */
        UD60x18 dSlope;
    }

    struct RiskConfiguration {
        RiskMultipliers riskMultipliers;
        LiquidationConfiguration liquidationConfiguration;
        DutchConfiguration dutchConfiguration;
    }

    struct InsuranceFundConfig {
        /**
         * @dev Pool's insurance fund account ID
         */
        uint128 accountId;
        /**
         * @dev Percentage of liquidation penalty that goes towards the insurance fund
         */
        UD60x18 liquidationFee;
    }

    struct BackstopLPConfig {
        /**
         * @dev Backstop LP Account Id
         */
        uint128 accountId;

        /**
         * @dev Percentage of liquidation penalty that goes towards backstop lp
         */
        UD60x18 liquidationFee;

        /**
         * Lower bound threshold enforced on the total net deposits of the backstop lp
         * (in USD) in order to earn backstop rewards.
         */
        uint256 minNetDepositThresholdInUSD;

        /**
         * Duration in seconds of the period between withdrawal announcement
         * and the start of the withdrawal period (for backstop lp).
         */
        uint256 withdrawCooldownDurationInSeconds;

        /**
         * @notice Duration in seconds of the withdrawal period for the backstop lp
         */
        uint256 withdrawDurationInSeconds; 
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

        // block -> row -> column -> value
        mapping(uint256 => mapping(uint256 => mapping(uint256 => SD59x18))) riskMatrix;
        /**
         * @dev If proposed parent id is greater than 0, then the collateral pool awaits for approval from parent owner to merge. 
         */
        uint128 proposedParentId;
        /**
         * @dev Collateral pool wide insurance fund configuration 
         */
        InsuranceFundConfig insuranceFundConfig;

        // todo: expose these amounts via a view function and an external interface
        /**
         * @dev Funds underwritten by the insurance fund in terms of a given quote token
         */
        mapping(address => uint256) insuranceFundUnderwritings;

        /**
         * @dev Collateral pool wide backstop lp configuration
         */
        BackstopLPConfig backstopLPConfig;
        /**
         * @dev Account id for the collector of protocol fees
         */
        uint128 feeCollectorAccountId;
    }

    function updateInsuranceFundUnderwritings(Data storage self, address collateralType, uint256 amount) internal {
        // todo: make sure doesn't overflow insurance fund balance (import account.sol)
        self.insuranceFundUnderwritings[collateralType] += amount;
        // todo: emit event
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
            collateralPool.backstopLPConfig,
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
            updateCollateralShares(parent, activeCollateral, child.collateralShares[activeCollateral].toInt());
        }

        child.rootId = parent.id;

        emit CollateralPoolUpdated(
            child.id,
            child.rootId,
            child.riskConfig,
            child.insuranceFundConfig,
            child.backstopLPConfig,
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

    function checkCap(Data storage self, address collateralType)
        private 
        view 
    {
        // Check that this deposit does not reach the cap
        uint256 collateralCap = CollateralConfiguration.exists(self.id, collateralType).baseConfig.cap;

        // If the cap is maximum, bypass this check to avoid fetching the collateral balance
        if (collateralCap == type(uint256).max) {
            return;
        }

        // Fetch the collateral balance
        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        // Check the cap
        if (collateralBalance > collateralCap) {
            revert CollateralCapExceeded(self.id, collateralType, collateralCap, collateralBalance);
        }
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the collateral pool
     */
    function getCollateralBalance(
        Data storage self,
        address collateralType
    ) 
        internal
        view
        returns(uint256) 
    {
        if (!self.isRoot()) {
            return 0;
        }

        GlobalCollateralConfiguration.Data storage globalConfig = GlobalCollateralConfiguration.exists(collateralType);
        return globalConfig.convertToAssets(self.collateralShares[collateralType]);
    }

    // todo: expose this function as collateral pool owner only
    function configureRiskMatrix(
        Data storage self,
        uint256 blockIndex,
        uint256 rowIndex,
        uint256 columnIndex,
        SD59x18 value
    ) internal {
        self.riskMatrix[blockIndex][rowIndex][columnIndex] = value;
    }

    function updateCollateralShares(
        Data storage self,
        address collateralType, 
        int256 sharesDelta
    ) internal {
        // check withdraw limits
        if (sharesDelta < 0) {
            CollateralConfiguration.exists(self.id, collateralType).checkWithdrawLimits((-sharesDelta).toUint());
        }
        
        // Update the collateral shares
        if (sharesDelta > 0) {
            self.collateralShares[collateralType] += sharesDelta.toUint();
        } else {
            self.collateralShares[collateralType] -= (-sharesDelta).toUint();
        }
         
        // Update the active collaterals list
        if (self.collateralShares[collateralType] > 0) {
            if (!self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.add(collateralType);
            }
        } else {
            if (self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.remove(collateralType);
            }
        }

        // Check that this deposit does not reach the cap
        checkCap(self, collateralType);

        emit CollateralPoolBalanceUpdated(self.id, collateralType, sharesDelta, block.timestamp);
    }

    /**
     * @dev Set the collateral pool wide risk configuration
     * @param config The ProtocolRiskConfiguration object with all the protocol-wide risk parameters
     */
    function setRiskConfiguration(Data storage self, RiskConfiguration memory config) internal {
        self.checkRoot();

        self.riskConfig = config;

        emit CollateralPoolUpdated(
            self.id, 
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.backstopLPConfig,
            self.feeCollectorAccountId,
            block.timestamp
        );
    }

    /**
     * @dev Set the collateral pool wide insurance fund configuration
     * @param config The InsuranceFundConfig object with the account id and fee configs
     */
    function setInsuranceFundConfig(Data storage self, InsuranceFundConfig memory config) internal {
        self.checkRoot();

        // ensure the given account exists
        Account.exists(config.accountId);
        self.insuranceFundConfig = config;

        emit CollateralPoolUpdated(
            self.id,
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.backstopLPConfig,
            self.feeCollectorAccountId,
            block.timestamp
        );
    }

    // todo: expose in the collateral pool config module
    /**
     * @dev Set the collateral pool wide backstop lp configuration
     * @param config The BackstopLPConfig object with the account id and fee config
     */
    function setBackstopLPConfig(Data storage self, BackstopLPConfig memory config) internal {
        self.checkRoot();

        // ensure the given account exists
        Account.exists(config.accountId);

        self.backstopLPConfig = config;

        emit CollateralPoolUpdated(
            self.id,
            self.rootId,
            self.riskConfig,
            self.insuranceFundConfig,
            self.backstopLPConfig,
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
            self.backstopLPConfig,
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