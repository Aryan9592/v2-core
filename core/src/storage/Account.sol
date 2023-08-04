/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "./Market.sol";
import "./ProtocolRiskConfiguration.sol";
import "./CollateralConfiguration.sol";
import "./AccountRBAC.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "./CollateralPool.sol";

import "oz/utils/math/Math.sol";
import "oz/utils/math/SignedMath.sol";

// todo: consider moving into ProbMathHelper.sol
import {UD60x18, sub as subSD59x18} from "@prb/math/SD59x18.sol";
import {mulUDxUint, mulUDxInt, mulSDxInt, sd59x18, SD59x18, UD60x18} 
    from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: this file is getting quite large, consider abstracting away some of the pure functions into libraries (CR)
/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
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
    using CollateralPool for CollateralPool.Data;

    //// ERRORS and STRUCTS ////

    /**
     * @dev Thrown when the given target address does not own the given account.
     */
    error PermissionDenied(uint128 accountId, address target);

    /**
     * @dev Thrown when a given single-token account's account's total value is below the initial margin requirement
     * + the highest unrealized loss
     */
    error AccountBelowIM(uint128 accountId, address collateralType, MarginRequirements marginRequirements);

    /**
     * @dev Thrown when an account cannot be found.
     */
    error AccountNotFound(uint128 accountId);

    /**
     * @dev Thrown when an account does not have sufficient collateral.
     */
    error InsufficientCollateral(uint128 accountId, address collateralType, uint256 requestedAmount);

    /**
     * @notice Thrown when an attempt to propagate an order with a market with which the account cannot engage.
     */
    // todo: consider if more information needs to be included in this error beyond accountId and marketId
    error AccountCannotEngageWithMarket(uint128 accountId, uint128 marketId);

    /**
     * @notice Emitted when collateral balance of account token with id `accountId` is updated.
     * @param accountId The id of the account.
     * @param collateralType The address of the collateral type.
     * @param tokenAmount The change delta of the collateral balance.
     * @param blockTimestamp The current block timestamp.
     */
    event CollateralUpdate(uint128 indexed accountId, address indexed collateralType, int256 tokenAmount, uint256 blockTimestamp);

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
        mapping(address => uint256) collateralBalances;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeCollaterals;
    
        /**
         * @dev Ids of all the markets in which the account has active positions by quote token
         */
        mapping(address => SetUtil.UintSet) activeMarketsPerQuoteToken;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        SetUtil.AddressSet activeQuoteTokens;

        /**
         * @dev First market id that this account is active on
         */
        uint128 firstMarketId;

        /**
         * @dev If this boolean is set to true then the account is able to cross-collateral margin
         * @dev If this boolean is set to false then the account uses a single-token mode
         * @dev Single token mode means the account has a separate health factor for each collateral type
         */
        // todo: should we change this from boolean to something more general? What if we're gonna have some other mode? 
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

    struct MarginRequirements {
        bool isIMSatisfied;
        bool isLMSatisfied;
        uint256 initialMarginRequirement;
        uint256 liquidationMarginRequirement;
        uint256 highestUnrealizedLoss;
    }

    //// STATE CHANGING FUNCTIONS ////

    /**
     * @dev Increments the account's collateral balance.
     */
    function increaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        // increase collateral balance
        self.collateralBalances[collateralType] += amount;

        // add the collateral type to the active collaterals if missing
        if (self.collateralBalances[collateralType] > 0) {
            if (!self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.add(collateralType);
            }
        }

        // update the corresponding collateral pool balance
        Market.exists(self.firstMarketId)
            .getCollateralPool()
            .increaseCollateralBalance(collateralType, amount);

        // emit event
        emit CollateralUpdate(self.id, collateralType, amount.toInt(), block.timestamp);
    }

    /**
     * @dev Decrements the account's collateral balance.
     */
    function decreaseCollateralBalance(Data storage self, address collateralType, uint256 amount) internal {
        // check collateral balance and revert if not sufficient
        if (self.collateralBalances[collateralType] < amount) {
            revert InsufficientCollateral(self.id, collateralType, amount);
        }

        // decrease collateral balance
        self.collateralBalances[collateralType] -= amount;

        // remove the collateral type from the active collaterals if balance goes to zero
        if (self.collateralBalances[collateralType] == 0) {
            if (self.activeCollaterals.contains(collateralType)) {
                self.activeCollaterals.remove(collateralType);
            }
        }

        // update the corresponding collateral pool balance
        Market.exists(self.firstMarketId)
            .getCollateralPool()
            .decreaseCollateralBalance(collateralType, amount);

        // emit event
        emit CollateralUpdate(self.id, collateralType, -amount.toInt(), block.timestamp);
    }

    /**
     * @dev Marks that the account is active on particular market.
     */
    function markActiveMarket(Data storage self, address collateralType, uint128 marketId) internal {
        // skip if account is already active on this market
        if (self.activeMarketsPerQuoteToken[collateralType].contains(marketId)) {
            return;
        }

        // check if account can interact with this market
        if (self.firstMarketId == 0) {
            self.firstMarketId = marketId;
        }
        else {
            // get collateral pool ID of the account
            uint128 accountCollateralPoolId = 
                Market.exists(self.firstMarketId).getCollateralPool().id;
    
            // get collateral pool ID of the new market
            uint128 marketCollateralPoolId = 
                Market.exists(marketId).getCollateralPool().id;

            // if the collateral pools are different, account cannot engage with the new market
            if (accountCollateralPoolId != marketCollateralPoolId) {
                revert AccountCannotEngageWithMarket(self.id, marketId);
            }
        }

        // add the collateral type to the account active quote tokens if missing
        if (!self.activeQuoteTokens.contains(collateralType)) {
            self.activeQuoteTokens.add(collateralType);
        }

        // add the market to the account active markets
        self.activeMarketsPerQuoteToken[collateralType].add(marketId);
    }

    /**
     * @dev Marks that the account is active on particular market.
     */
    function changeAccountMode(Data storage self, bool isMultiToken) internal {
        if (self.isMultiToken == isMultiToken) {
            // todo: return vs revert
            return;
        }

        self.isMultiToken = isMultiToken;

        if (isMultiToken) {
            self.imCheck(address(0));
        }
        else {
            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);
                self.imCheck(quoteToken);
            }
        }
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
            Market.exists(marketId).closeAccount(self.id);
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
        collateralBalance = self.collateralBalances[collateralType];
    }


    /**
     * @dev Given a collateral type, returns information about the total balance of the account that's available to withdraw
     */
    function getCollateralBalanceAvailable(Data storage self, address collateralType)
        internal
        view
        returns (uint256 collateralBalanceAvailable)
    {
        if (self.isMultiToken) {
            // get im and lm requirements and highest unrealized pnl in USD
            MarginRequirements memory mrInUSD = self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

            // get account weighted balance in USD
            uint256 weightedBalanceInUSD = self.getWeightedCollateralBalanceInUSD();

            // check if there's any available balance in USD
            if (weightedBalanceInUSD >= mrInUSD.initialMarginRequirement + mrInUSD.highestUnrealizedLoss) {
                // get the available weighted balance in USD
                uint256 availableWeightedBalanceInUSD = 
                    weightedBalanceInUSD - mrInUSD.initialMarginRequirement - mrInUSD.highestUnrealizedLoss;

                // convert weighted balance in USD to collateral
                uint256 availableAmountInCollateral = 
                    CollateralConfiguration.load(collateralType).getWeightedUSDInCollateral(availableWeightedBalanceInUSD);

                // get the account collateral balance
                uint256 collateralBalance = self.getCollateralBalance(collateralType);

                // return the minimum between account collateral balance and available collateral
                collateralBalanceAvailable = 
                    (collateralBalance < availableAmountInCollateral) 
                        ? collateralBalance 
                        : availableAmountInCollateral;
            }
        }
        else {
            // get im and lm requirements and highest unrealized pnl in collateral
            MarginRequirements memory mr = self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);

            // get the account collateral balance
            uint256 collateralBalance = self.getCollateralBalance(collateralType);

            if (collateralBalance >= mr.initialMarginRequirement + mr.highestUnrealizedLoss) {
                // return the available collateral balance
                collateralBalanceAvailable = collateralBalance - mr.initialMarginRequirement - mr.highestUnrealizedLoss;
            }
        }
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
        return Market.exists(marketId).riskConfig.riskParameter;
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
    function imCheck(Data storage self, address collateralType) 
        internal 
        view 
        returns (MarginRequirements memory mr)
    {
        mr = self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
        
        if (!mr.isIMSatisfied) {
            revert AccountBelowIM(self.id, collateralType, mr);
        }
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account and highest unrealized loss
     * for a given collateral type along with the flags for im or lm satisfied
     * @dev If the account is single-token, the amounts are in collateral type. 
     *      Otherwise, if the account is multi-token, the amounts are in USD.
     */
    // todo: do we want for this function to return values in USD or leave for collateral type?
    function getMarginRequirementsAndHighestUnrealizedLoss(Data storage self, address collateralType)
        internal
        view
        returns (MarginRequirements memory mr)
    {
        uint256 collateralBalance = 0;
    
        if (self.isMultiToken) {

            for (uint256 i = 1; i <= self.activeQuoteTokens.length(); i++) {
                address quoteToken = self.activeQuoteTokens.valueAt(i);
                CollateralConfiguration.Data storage collateral = CollateralConfiguration.load(quoteToken);

                (uint256 liquidationMarginRequirementInCollateral, uint256 highestUnrealizedLossInCollateral) = 
                    self.getRequirementsAndHighestUnrealizedLossByCollateralType(quoteToken);

                uint256 liquidationMarginRequirementInUSD = collateral.getCollateralInUSD(liquidationMarginRequirementInCollateral);
                uint256 highestUnrealizedLossInUSD = collateral.getCollateralInUSD(highestUnrealizedLossInCollateral);

                mr.liquidationMarginRequirement += liquidationMarginRequirementInUSD;
                mr.highestUnrealizedLoss += highestUnrealizedLossInUSD;
            }

            collateralBalance = self.getWeightedCollateralBalanceInUSD();
        }
        else {
            // we don't need to convert the amounts to USD because single-token accounts have requirements in quote token

            (mr.liquidationMarginRequirement, mr.highestUnrealizedLoss) = 
                    self.getRequirementsAndHighestUnrealizedLossByCollateralType(collateralType);

            collateralBalance = self.getCollateralBalance(collateralType);
        }

        UD60x18 imMultiplier = getIMMultiplier();
        mr.initialMarginRequirement = computeInitialMarginRequirement(mr.liquidationMarginRequirement, imMultiplier);

        mr.isIMSatisfied = collateralBalance >= mr.initialMarginRequirement + mr.highestUnrealizedLoss;
        mr.isLMSatisfied = collateralBalance >= mr.liquidationMarginRequirement + mr.highestUnrealizedLoss;
    }

    /**
     * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account and highest unrealized loss
     * for a given collateral type along with the flags for im satisfied or lm satisfied
     * @dev If the account is single-token, the amounts are in collateral type. 
     *      Otherwise, if the account is multi-token, the amounts are in USD.
     */
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
            MakerMarketExposure[] memory makerExposures = 
                Market.exists(marketId).getAccountTakerAndMakerExposures(self.id);

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
        for (uint256 i = 1; i <= self.activeCollaterals.length(); i++) {
            address collateralType = self.activeCollaterals.valueAt(i);

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
