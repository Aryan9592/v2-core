/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./MarketRiskConfiguration.sol";
import "./ProtocolRiskConfiguration.sol";
import "./CollateralConfiguration.sol";
import "./AccountRBAC.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "./Market.sol";

import "oz/utils/math/Math.sol";
import "oz/utils/math/SignedMath.sol";

// todo: consider moving into ProbMathHelper.sol
import {UD60x18, sub as subSD59x18} from "@prb/math/SD59x18.sol";
import {mulUDxUint, mulUDxInt, mulSDxInt, sd59x18, SD59x18, UD60x18} 
    from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: this file is getting quite large, consider abstracting away some of the pure functions into libraries (CR)
// todo: note, a few of the functions in this library have two representations (one for a single collateral
// and one for all collaterals with potentially a lot of duplicate logic that can in be abstracted away (CR)
/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using MarketRiskConfiguration for MarketRiskConfiguration.Data;
    using ProtocolRiskConfiguration for ProtocolRiskConfiguration.Data;
    using Account for Account.Data;
    using AccountRBAC for AccountRBAC.Data;
    using Market for Market.Data;
    using SetUtil for SetUtil.UintSet;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastU128 for uint128;
    using SafeCastU256 for uint256;
    using SafeCastI256 for int256;
    using CollateralConfiguration for CollateralConfiguration.Data;

    //// ERRORS and STRUCTS ////

    /**
     * @dev Thrown when the given target address does not own the given account.
     */
    error PermissionDenied(uint128 accountId, address target);

    /**
     * @dev Thrown when a given single-token account's account's total value is below the initial margin requirement
     * + the highest unrealized loss
     */
    error AccountBelowIM(uint128 accountId, address collateralType, uint256 initialMarginRequirement, uint256 highestUnrealizedLoss);

    /**
     * @dev Thrown when an account cannot be found.
     */
    error AccountNotFound(uint128 accountId);

    /**
     * @dev Thrown when an account does not have sufficient collateral.
     */
    error InsufficientCollateral(uint128 accountId, address collateralType, uint256 requestedAmount);

    /**
     * @dev Thrown when an account does not have sufficient collateral.
     */
    error InsufficientLiquidationBoosterBalance(uint128 accountId, address collateralType, uint256 requestedAmount);

    /**
     * @notice Emitted when collateral balance of account token with id `accountId` is updated.
     * @param accountId The id of the account.
     * @param collateralType The address of the collateral type.
     * @param tokenAmount The change delta of the collateral balance.
     * @param blockTimestamp The current block timestamp.
     */
    event CollateralUpdate(uint128 indexed accountId, address indexed collateralType, int256 tokenAmount, uint256 blockTimestamp);

    /**
     * @notice Emitted when liquidator booster deposit of `accountId` is updated.
     * @param accountId The id of the account.
     * @param collateralType The address of the collateral type.
     * @param tokenAmount The change delta of the collateral balance.
     * @param blockTimestamp The current block timestamp.
     */
    event LiquidatorBoosterUpdate(
        uint128 indexed accountId, 
        address indexed collateralType, 
        int256 tokenAmount, 
        uint256 blockTimestamp
    );

    struct Data {
        /**
         * @dev Numeric identifier for the account. Must be unique.
         * @dev There cannot be an account with id zero (See ERC721._mint()).
         */
        uint128 id;
    
        /**
         * @dev Role based access control data for the account.
         */
        AccountRBAC.Data rbac;
    
        /**
         * @dev Address set of collaterals that are being used in the protocols by this account.
         */
        mapping(address => Collateral) collaterals;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        // todo: layer in logic that updates this set upon collateral deposits and withdrawals (CR)
        SetUtil.AddressSet activeCollaterals;
    
        /**
         * @dev Ids of all the markets in which the account has active positions by quote token
         */
        mapping(address => SetUtil.UintSet) activeMarketsPerQuoteToken;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeQuoteTokens;

        // todo: add support for corresponding collateral pool

        /**
         * @dev If this boolean is set to true then the account is able to cross-collateral margin
         * @dev If this boolean is set to false then the account uses a single-token mode
         * @dev Single token mode means the account has a separate health factor for each collateral type
         */
        bool isMultiToken;

        // todo: consider introducing empty slots for future use (also applies to other storage objects) (CR)
        // ref: https://github.com/Synthetixio/synthetix-v3/blob/08ea86daa550870ec07c47651394dbb0212eeca0/protocol/
        // synthetix/contracts/storage/Account.sol#L58
    }

    /**
     * @dev Note, for dated instruments we don't need to keep track of the maturity
     because the risk parameter is shared across maturities for a given marketId
     */
    struct MarketExposure {
        int256 annualizedNotional;
        // note, in context of dated irs with the current accounting logic it also includes accruedInterest
        uint256 unrealizedLoss;
    }

    struct MakerMarketExposure {
        MarketExposure lower;
        MarketExposure upper;
    }

    /**
    * @title Stores information about a deposited asset for a given account.
    *
    * Each account will have one of these objects for each type of collateral it deposited in the system.
    */
    struct Collateral {
        /**
         * @dev The net amount that is deposited in this collateral
         */
        uint256 balance;
        /**
         * @dev The amount of tokens the account has in liquidation booster. Max value is
         * @dev liquidation booster defined in CollateralConfiguration.
         */
        uint256 liquidationBoosterBalance;
    }

    //// STATE CHANGING FUNCTIONS ////

    /**
     * @dev Increments the account's collateral balance.
     */
    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        self.collaterals[collateralType].balance += amount;

        emit CollateralUpdate(self.id, collateralType, amount.toInt(), block.timestamp);
    }

    /**
     * @dev Decrements the account's collateral balance.
     */
    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        if (self.collaterals[collateralType].balance < amount) {
            revert InsufficientCollateral(self.id, collateralType, amount);
        }

        self.collaterals[collateralType].balance -= amount;

        emit CollateralUpdate(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    /**
     * @dev Increments the account's liquidation booster balance.
     */
    function increaseLiquidationBoosterBalance(Data storage self, address collateralType, uint256 amount) internal {
       self.collaterals[collateralType].liquidationBoosterBalance += amount;

       emit LiquidatorBoosterUpdate(self.id, collateralType, amount.toInt(), block.timestamp);
    }

    /**
     * @dev Decrements the account's liquidation booster balance.
     */
    function decreaseLiquidationBoosterBalance(Data storage self, address collateralType, uint256 amount) internal {
        if (self.collaterals[collateralType].liquidationBoosterBalance < amount) {
            revert InsufficientLiquidationBoosterBalance(self.id, collateralType, amount);
        }

        self.collaterals[collateralType].liquidationBoosterBalance -= amount;

        emit LiquidatorBoosterUpdate(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    /**
     * @dev Creates an account for the given id, and associates it to the given owner.
     *
     * Note: Will not fail if the account already exists, and if so, will overwrite the existing owner.
     *  Whatever calls this internal function must first check that the account doesn't exist before re-creating it.
     */
    function create(uint128 id, address owner, bool isMultiToken) 
        internal 
        returns (Data storage account) 
    {
        // Disallowing account ID 0 means we can use a non-zero accountId as an existence flag in structs like Position
        require(id != 0);

        account = load(id);

        account.id = id;
        account.rbac.owner = owner;
        account.isMultiToken = isMultiToken;
    }

    /**
     * @dev Closes all account filled (i.e. attempts to fully unwind) and unfilled orders in all the markets in which the account
     * is active
     */
    function closeAccount(Data storage self, address collateralType) internal {
        SetUtil.UintSet storage markets = self.activeMarketsPerQuoteToken[collateralType];
            
        for (uint256 i = 1; i <= markets.length(); i++) {
            uint128 marketId = markets.valueAt(i).to128();
            Market.load(marketId).closeAccount(self.id);
        }
    }

    //// VIEW FUNCTIONS ////

    /**
     * @dev Reverts if the account does not exist with appropriate error. Otherwise, returns the account.
     */
    function exists(uint128 id) internal view returns (Data storage account) {
        Data storage a = load(id);
        if (a.rbac.owner == address(0)) {
            revert AccountNotFound(id);
        }

        return a;
    }

    /**
     * @dev Given a collateral type, returns information about the collateral balance of the account
     */
    function getCollateralBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256 collateralBalance)
    {
        collateralBalance = self.collaterals[collateralType].balance;
    }


    // todo: consider introducing a multi-token counterpart for this function? (CR)
    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getCollateralBalanceAvailable(Data storage self, address collateralType)
        internal
        view
        returns (uint256 collateralBalanceAvailable)
    {
        (uint256 initialMarginRequirement,,uint256 highestUnrealizedLoss) = 
            self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        uint256 collateralBalance = self.getCollateralBalance(collateralType);

        if (collateralBalance > initialMarginRequirement + highestUnrealizedLoss) {
            collateralBalanceAvailable = collateralBalance - initialMarginRequirement - highestUnrealizedLoss;
        }

    }

    /**
     * @dev Given a collateral type, returns information about the total liquidation booster balance of the account
     */
    function getLiquidationBoosterBalance(Data storage self, address collateralType)
        internal
        view
        returns (uint256 liquidationBoosterBalance)
    {
        liquidationBoosterBalance = self.collaterals[collateralType].liquidationBoosterBalance;
    }

    /**
     * @dev Loads the Account object for the specified accountId,
     * and validates that sender has the specified permission. It also resets
     * the interaction timeout. These are different actions but they are merged
     * in a single function because loading an account and checking for a
     * permission is a very common use case in other parts of the code.
     */
    function loadAccountAndValidateOwnership(uint128 accountId, address senderAddress)
        internal
        view
        returns (Data storage account)
    {
        account = Account.load(accountId);
        if (account.rbac.owner != senderAddress) {
            revert PermissionDenied(accountId, senderAddress);
        }
    }

    /**
     * @dev Loads the Account object for the specified accountId,
     * and validates that sender has the specified permission. It also resets
     * the interaction timeout. These are different actions but they are merged
     * in a single function because loading an account and checking for a
     * permission is a very common use case in other parts of the code.
     */
    function loadAccountAndValidatePermission(uint128 accountId, bytes32 permission, address senderAddress)
        internal
        view
        returns (Data storage account)
    {
        account = Account.load(accountId);
        if (!account.rbac.authorized(permission, senderAddress)) {
            revert PermissionDenied(accountId, senderAddress);
        }
    }

    function getRiskParameter(uint128 marketId) internal view returns (UD60x18 riskParameter) {
        return MarketRiskConfiguration.load(marketId).riskParameter;
    }

    /**
     * @dev Note, im multiplier is assumed to be the same across all markets and maturities
     */
    function getIMMultiplier() internal view returns (UD60x18 imMultiplier) {
        return ProtocolRiskConfiguration.load().imMultiplier;
    }

    /**
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise  returns the initial margin requirement (single token account)
     */
    function imCheck(Data storage self, address collateralType) internal view returns (uint256, uint256) {
        (bool isSatisfied, uint256 initialMarginRequirement, uint256 highestUnrealizedLoss) = self.isIMSatisfied(collateralType);
        if (!isSatisfied) {
            revert AccountBelowIM(self.id, collateralType, initialMarginRequirement, highestUnrealizedLoss);
        }
        return (initialMarginRequirement, highestUnrealizedLoss);
    }

    /**
     * @dev Returns a boolean imSatisfied (true if the account is above initial margin requirement) and
     * the initial margin requirement for a given collateral type (single token account)
     */
    function isIMSatisfied(Data storage self, address collateralType)
        internal
        view
    returns (bool imSatisfied, uint256 initialMarginRequirement, uint256 highestUnrealizedLoss) {
        (initialMarginRequirement,,highestUnrealizedLoss) = self.
                getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        uint256 collateralBalance = 
            (self.isMultiToken) 
                ? self.getWeightedCollateralBalanceInUSD() 
                : self.getCollateralBalance(collateralType);
    
        imSatisfied = collateralBalance >= initialMarginRequirement + highestUnrealizedLoss;
    }

    /**
     * @dev Returns a booleans liquidatable (true if a single-token account is below liquidation margin requirement)
     * and the initial and liquidation margin requirements alongside highest unrealized loss
     */
    function isLiquidatable(Data storage self, address collateralType)
        internal
        view
        returns (
            bool liquidatable,
            uint256 initialMarginRequirement,
            uint256 liquidationMarginRequirement,
            uint256 highestUnrealizedLoss
        )
    {
        (initialMarginRequirement, liquidationMarginRequirement, highestUnrealizedLoss) = self.
                getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

        uint256 collateralBalance = 
            (self.isMultiToken) 
                ? self.getWeightedCollateralBalanceInUSD() 
                : self.getCollateralBalance(collateralType);
    
        liquidatable = collateralBalance < liquidationMarginRequirement + highestUnrealizedLoss;
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account alongside highest unrealized loss
     * for a given collateral type
     */

    function getMarginRequirementsAndHighestUnrealizedLoss(Data storage self, address collateralType)
        internal
        view
        returns (uint256 initialMarginRequirement, uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss)
    {
        if (self.isMultiToken) {
            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);

                (uint256 liquidationMarginRequirementByCollateral, uint256 highestUnrealizedLossByCollateral) = 
                    self.getRequirementsAndHighestUnrealizedLossByCollateralType(quoteToken);

                // todo: convert amounts per token to USD and aggregate them
            }
        }
        else {
            (liquidationMarginRequirement, highestUnrealizedLoss) = 
                    self.getRequirementsAndHighestUnrealizedLossByCollateralType(collateralType);
            
            // don't convert to USD because single token accounts have requirements in quote token
        }


        UD60x18 imMultiplier = getIMMultiplier();
        initialMarginRequirement = computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);
    }

    function getRequirementsAndHighestUnrealizedLossByCollateralType(Data storage self, address collateralType)
        internal
        view
        returns (uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss)
    {
        SetUtil.UintSet storage markets = self.activeMarketsPerQuoteToken[collateralType];

        for (uint256 i = 1; i <= markets.length(); i++) {
            uint128 marketId = markets.valueAt(i).to128();

            // Get the risk parameter of the market
            UD60x18 riskParameter = getRiskParameter(marketId);

            // Get taker and maker exposure to the market
            MakerMarketExposure[] memory makerExposures = Market.load(marketId).getAccountTakerAndMakerExposures(self.id);

            // Aggregate LMR and unrealized loss for all exposures
            for (uint256 j = 0; j < makerExposures.length; j++) {
                MarketExposure memory exposureLower = makerExposures[j].lower;
                MarketExposure memory exposureUpper = makerExposures[j].upper;

                uint256 lowerLMR = 
                    computeLiquidationMarginRequirement(exposureLower.annualizedNotional, riskParameter);

               if (equalExposures(exposureLower, exposureUpper)) {
                    liquidationMarginRequirement += lowerLMR;
                    highestUnrealizedLoss += exposureLower.unrealizedLoss;
               }
               else {
                    uint256 upperLMR = 
                        computeLiquidationMarginRequirement(exposureUpper.annualizedNotional, riskParameter);

                    if (
                        lowerLMR + exposureLower.unrealizedLoss >
                        upperLMR + exposureUpper.unrealizedLoss
                    ) {
                        liquidationMarginRequirement += lowerLMR;
                        highestUnrealizedLoss += exposureLower.unrealizedLoss;
                    } else {
                        liquidationMarginRequirement += upperLMR;
                        highestUnrealizedLoss += exposureUpper.unrealizedLoss;
                    }
               }
            
                
            }
        }
    }

    function getWeightedCollateralBalanceInUSD(Data storage self) 
    internal 
    view
    returns (uint256 weightedCollateralBalanceInUSD) 
    {
        // retrieve all active collaterals of the account
        SetUtil.AddressSet storage activeCollaterals = self.activeCollaterals;

        for (uint256 i = 1; i <= activeCollaterals.length(); i++) {
            address collateralType = activeCollaterals.valueAt(i);

            // get the collateral balance of the account in this collateral type
            uint256 collateralBalance = self.getCollateralBalance(collateralType);

            // aggregate the corresponding weighted amount in USD 
            weightedCollateralBalanceInUSD += 
                CollateralConfiguration.load(collateralType).getWeightedCollateralInUSD(collateralBalance);
        }
    }


    function isEligibleForAutoExchange(Data storage self) internal view returns (bool) {

        // note, only applies to multi-token accounts
        // todo: needs to be exposed via e.g. the account module
        // todo: needs implementation -> within this need to take into account product -> market changes

        return false;

    }


    //// PURE FUNCTIONS ////

    /**
     * @dev Returns the account stored at the specified account id.
     */
    function load(uint128 id) internal pure returns (Data storage account) {
        require(id != 0);
        bytes32 s = keccak256(abi.encode("xyz.voltz.Account", id));
        assembly {
            account.slot := s
        }
    }


    /**
     * @dev Returns the liquidation margin requirement given the annualized exposure and the risk parameter
     */
    function computeLiquidationMarginRequirement(int256 annualizedNotional, UD60x18 riskParameter)
    internal
    pure
    returns (uint256 liquidationMarginRequirement)
    {

        uint256 absAnnualizedNotional = annualizedNotional < 0 ? uint256(-annualizedNotional) : uint256(annualizedNotional);
        liquidationMarginRequirement = mulUDxUint(riskParameter, absAnnualizedNotional);
        return liquidationMarginRequirement;
    }

    /**
     * @dev Returns the initial margin requirement given the liquidation margin requirement and the im multiplier
     */
    function computeInitialMarginRequirement(uint256 liquidationMarginRequirement, UD60x18 imMultiplier)
    internal
    pure
    returns (uint256 initialMarginRequirement)
    {
        initialMarginRequirement = mulUDxUint(imMultiplier, liquidationMarginRequirement);
    }

    function equalExposures(MarketExposure memory a, MarketExposure memory b) internal pure returns (bool) {
        if (
            a.annualizedNotional == b.annualizedNotional && 
            a.unrealizedLoss == b.unrealizedLoss
        ) {
            return true;
        }

        return false;
    }
}
