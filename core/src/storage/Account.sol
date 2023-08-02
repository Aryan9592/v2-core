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
import "./Product.sol";

import "oz/utils/math/Math.sol";
import "oz/utils/math/SignedMath.sol";

// todo: consider moving into ProbMathHelper.sol
import {UD60x18, sub as subSD59x18} from "@prb/math/SD59x18.sol";
import {mulUDxUint, mulUDxInt, mulSDxInt, sd59x18, SD59x18, UD60x18} 
    from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

// todo: this file is getting quite large, consider abstracting away some of the pure functions into libraries (CR)
// todo: note, a few of the functions in this library have two representations (one for a single collateral
// and one for all collaterals with potentially a lot of duplicate logic that can in be abstracted away (CR)
// todo: consider replacing the AllCollaterals suffix with MultiToken? (CR)
/**
 * @title Object for tracking accounts with access control and collateral tracking.
 */
library Account {
    using MarketRiskConfiguration for MarketRiskConfiguration.Data;
    using ProtocolRiskConfiguration for ProtocolRiskConfiguration.Data;
    using Account for Account.Data;
    using AccountRBAC for AccountRBAC.Data;
    using Product for Product.Data;
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
     * @dev Thrown when a given multi-token account's total value is below the initial margin requirement
     * + the highest unrealized loss in USD
     */
    error AccountBelowIMAllCollaterals(uint128 accountId, uint256 initialMarginRequirementInUSD,
        uint256 highestUnrealizedLossInUSD);

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
         * @dev Ids of all the products in which the account has active positions
         */
        SetUtil.UintSet activeProducts;

        /**
         * @dev If this value is set to max uint128, then the account is only able to interact with trusted instruments
         */
        uint128 trustlessProductIdTrustedByAccount;

        /**
         * @dev If this boolean is set to true then the account is able to cross-collateral margin
         * @dev If this boolean is set to false then the account uses a single-token mode
         * @dev Single token mode means the account has a separate health factor for each collateral type
         */
        bool isMultiToken;

        /**
         * @dev Addresses of all collateral types in which the account has a non-zero balance
         */
        // todo: layer in logic that updates this set upon collateral deposits and withdrawals (CR)
        SetUtil.AddressSet activeCollateralTokenAddresses;

        // todo: consider introducing empty slots for future use (also applies to other storage objects) (CR)
        // ref: https://github.com/Synthetixio/synthetix-v3/blob/08ea86daa550870ec07c47651394dbb0212eeca0/protocol/
        // synthetix/contracts/storage/Account.sol#L58

    }

    /**
     * @dev productId (IRS) -> marketID (aUSDC lend) -> maturity (30th December)
     * @dev productId (Dated Future) -> marketID (BTC) -> maturity (30th December)
     * @dev productId (Perp) -> marketID (ETH)
     * @dev Note, for dated instruments we don't need to keep track of the maturity
     because the risk parameter is shared across maturities for a given productId marketId pair
     * @dev we need reference to productId & marketId to be able to derive the risk parameters for lm calculation
     */
    struct Exposure {
        uint128 productId;
        uint128 marketId;
        int256 annualizedNotional;
        // note, in context of dated irs with the current accounting logic it also includes accruedInterest
        uint256 unrealizedLoss;
        address collateralType;
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
    function create(uint128 id, address owner, uint128 trustlessProductIdTrustedByAccount, bool isMultiToken) 
        internal 
        returns (Data storage account) 
    {
        // Disallowing account ID 0 means we can use a non-zero accountId as an existence flag in structs like Position
        // todo: consider layering in validation of trustlessProductIdTrustedByAccount (AN)
        require(id != 0);
        account = load(id);

        account.id = id;
        account.rbac.owner = owner;
        account.trustlessProductIdTrustedByAccount = trustlessProductIdTrustedByAccount;
        account.isMultiToken = isMultiToken;
    }

    /**
     * @dev Closes all account filled (i.e. attempts to fully unwind) and unfilled orders in all the products in which the account
     * is active
     */
    function closeAccount(Data storage self, address collateralType) internal {
        SetUtil.UintSet storage _activeProducts = self.activeProducts;
        for (uint256 i = 1; i <= _activeProducts.length(); i++) {
            uint128 productIndex = _activeProducts.valueAt(i).to128();
            Product.Data storage _product = Product.load(productIndex);
            _product.closeAccount(self.id, collateralType);
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

    /**
     * @dev Returns the aggregate exposures of the account in all products in which the account is active (
     * exposures are per product) given a collateral type
     */
    function getProductTakerAndMakerExposures(Data storage self, uint128 productId, address collateralType)
        internal
        view
        returns (
            Exposure[] memory productTakerExposures,
            Exposure[] memory productMakerExposuresLower,
            Exposure[] memory productMakerExposuresUpper
        )
    {
        Product.Data storage _product = Product.load(productId);
        (productTakerExposures, productMakerExposuresLower, productMakerExposuresUpper) = 
            _product.getAccountTakerAndMakerExposures(self.id, collateralType);
    }

    /**
    * @dev Returns the aggregate exposures of the account in all products in which the account is active (
     * exposures are per product) for all collateral types
     */
    function getProductTakerAndMakerExposuresAllCollaterals(Data storage self, uint128 productId)
    internal
    view
    returns (
        Exposure[] memory productTakerExposures,
        Exposure[] memory productMakerExposuresLower,
        Exposure[] memory productMakerExposuresUpper
    )
    {
        Product.Data storage _product = Product.load(productId);
        (productTakerExposures, productMakerExposuresLower, productMakerExposuresUpper) =
        _product.getAccountTakerAndMakerExposuresAllCollaterals(self.id);
    }


    function getRiskParameter(uint128 productId, uint128 marketId) internal view returns (UD60x18 riskParameter) {
        return MarketRiskConfiguration.load(productId, marketId).riskParameter;
    }

    /**
     * @dev Note, im multiplier is assumed to be the same across all products, markets and maturities
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
     * @dev Checks if the account is below initial margin requirement and reverts if so,
     * otherwise returns the initial margin requirement in USD (multi token account)
     */
    function imCheckAllCollaterals(Data storage self) internal view returns (uint256, uint256) {
        (bool isSatisfied, uint256 initialMarginRequirementInUSD, uint256 highestUnrealizedLossInUSD) = self.
        isIMSatisfiedAllCollaterals();
        if (!isSatisfied) {
            revert AccountBelowIMAllCollaterals(self.id, initialMarginRequirementInUSD, highestUnrealizedLossInUSD);
        }
        return (initialMarginRequirementInUSD, highestUnrealizedLossInUSD);
    }


    /**
     * @dev Returns a boolean imSatisfied (true if the account is above initial margin requirement) and
     * the initial margin requirement for a given collateral type (single token account)
     */
    function isIMSatisfied(Data storage self, address collateralType)
        internal
        view
    returns (bool imSatisfied, uint256 initialMarginRequirement, uint256 highestUnrealizedLoss) {
        (initialMarginRequirement,,highestUnrealizedLoss) = self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
        uint256 collateralBalance = self.getCollateralBalance(collateralType);
        imSatisfied = collateralBalance >= initialMarginRequirement + highestUnrealizedLoss;
    }

    /**
     * @dev Returns a boolean imSatisfied (true if the account is above initial margin requirement) and
     * the initial margin requirement across collateral types (multi-token account)
     */
    function isIMSatisfiedAllCollaterals(Data storage self)
    internal
    view
    returns (bool imSatisfied, uint256 initialMarginRequirementInUSD, uint256 highestUnrealizedLossInUSD) {
        (initialMarginRequirementInUSD,,highestUnrealizedLossInUSD) = self.
        getMarginRequirementsAndHighestUnrealizedLossAllCollaterals();
        uint256 weightedCollateralBalanceInUSD = self.getWeightedCollateralBalanceInUSD();
        imSatisfied = weightedCollateralBalanceInUSD >= initialMarginRequirementInUSD + highestUnrealizedLossInUSD;
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
        (initialMarginRequirement, liquidationMarginRequirement, highestUnrealizedLoss) = 
            self.getMarginRequirementsAndHighestUnrealizedLoss(collateralType);
        uint256 collateralBalance = self.getCollateralBalance(collateralType);
        liquidatable = collateralBalance < liquidationMarginRequirement + highestUnrealizedLoss;
    }

    /**
     * @dev Returns a boolean isLiquidatable (true if the account is below liquidation margin requirement)
     * and the initial and liquidation margin requirements alongside highest unrealized loss (all in USD)
     */
    function isLiquidatableAllCollaterals(Data storage self)
    internal
    view
    returns (
        bool liquidatable,
        uint256 initialMarginRequirementInUSD,
        uint256 liquidationMarginRequirementInUSD,
        uint256 highestUnrealizedLossInUSD
    )
    {
        (initialMarginRequirementInUSD, liquidationMarginRequirementInUSD, highestUnrealizedLossInUSD) =
        self.getMarginRequirementsAndHighestUnrealizedLossAllCollaterals();
        uint256 weightedCollateralBalanceInUSD = self.getWeightedCollateralBalanceInUSD();
        liquidatable = weightedCollateralBalanceInUSD < liquidationMarginRequirementInUSD + highestUnrealizedLossInUSD;
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
        SetUtil.UintSet storage _activeProducts = self.activeProducts;

        for (uint256 i = 1; i <= _activeProducts.length(); i++) {
            uint128 productId = _activeProducts.valueAt(i).to128();

            (
                Exposure[] memory productTakerExposures,
                Exposure[] memory productMakerExposuresLower,
                Exposure[] memory productMakerExposuresUpper
            ) = self.getProductTakerAndMakerExposures(productId, collateralType);

            (uint256 lmTakerPositions, uint256 unrealizedLossTakerPositions) = computeLMAndUnrealizedLossFromExposures(
                productTakerExposures
            );
            (uint256 lmMakerPositions, uint256 highestUnrealizedLossMakerPositions) =
                computeLMAndHighestUnrealizedLossFromLowerAndUpperExposures(productMakerExposuresLower, productMakerExposuresUpper);
            liquidationMarginRequirement += (lmTakerPositions + lmMakerPositions);
            highestUnrealizedLoss += (unrealizedLossTakerPositions + highestUnrealizedLossMakerPositions);
        }

        UD60x18 imMultiplier = getIMMultiplier();
        initialMarginRequirement = computeInitialMarginRequirement(liquidationMarginRequirement, imMultiplier);
    }

    /**
    * @dev Returns the initial (im) and liquidataion (lm) margin requirements of the account alongside highest unrealized loss
     * across all collateral types
     */

    function getMarginRequirementsAndHighestUnrealizedLossAllCollaterals(Data storage self)
    internal
    view
    returns (uint256 initialMarginRequirementInUSD, uint256 liquidationMarginRequirementInUSD,
        uint256 highestUnrealizedLossInUSD)
    {
        SetUtil.UintSet storage _activeProducts = self.activeProducts;

        for (uint256 i = 1; i <= _activeProducts.length(); i++) {
            uint128 productId = _activeProducts.valueAt(i).to128();

            (
            Exposure[] memory productTakerExposures,
            Exposure[] memory productMakerExposuresLower,
            Exposure[] memory productMakerExposuresUpper
            ) = self.getProductTakerAndMakerExposuresAllCollaterals(productId);

            (uint256 lmTakerPositionsInUSD, uint256 unrealizedLossTakerPositionsInUSD) =
            computeLMAndUnrealizedLossFromExposuresAllCollaterals(
                productTakerExposures
            );
    
            (uint256 lmMakerPositionsInUSD, uint256 highestUnrealizedLossMakerPositionsInUSD) =
                computeLMAndHighestUnrealizedLossFromLowerAndUpperExposuresAllCollaterals(
                    productMakerExposuresLower, 
                    productMakerExposuresUpper
                );
            
            liquidationMarginRequirementInUSD += (lmTakerPositionsInUSD + lmMakerPositionsInUSD);
            highestUnrealizedLossInUSD += (unrealizedLossTakerPositionsInUSD + highestUnrealizedLossMakerPositionsInUSD);
        }

        UD60x18 imMultiplier = getIMMultiplier();
        initialMarginRequirementInUSD = computeInitialMarginRequirement(liquidationMarginRequirementInUSD, imMultiplier);
    }

    function computeLMAndHighestUnrealizedLossFromLowerAndUpperExposures(
        Exposure[] memory exposuresLower,
        Exposure[] memory exposuresUpper
    ) internal view
    returns (uint256 liquidationMarginRequirement, uint256 highestUnrealizedLoss)
    {

        require(exposuresLower.length == exposuresUpper.length);

        for (uint256 i=0; i < exposuresLower.length; i++) {
            require(exposuresLower[i].productId == exposuresUpper[i].productId);
            require(exposuresLower[i].marketId == exposuresUpper[i].marketId);
            Exposure memory exposureLower = exposuresLower[i];
            Exposure memory exposureUpper = exposuresUpper[i];
            UD60x18 riskParameter = getRiskParameter(exposureLower.productId, exposureLower.marketId);
            uint256 liquidationMarginRequirementExposureLower =
            computeLiquidationMarginRequirement(exposureLower.annualizedNotional, riskParameter);
            uint256 liquidationMarginRequirementExposureUpper =
            computeLiquidationMarginRequirement(exposureUpper.annualizedNotional, riskParameter);

            if (
                liquidationMarginRequirementExposureLower + exposureLower.unrealizedLoss >
                liquidationMarginRequirementExposureUpper + exposureUpper.unrealizedLoss
            ) {
                liquidationMarginRequirement += liquidationMarginRequirementExposureLower;
                highestUnrealizedLoss += exposureLower.unrealizedLoss;
            } else {
                liquidationMarginRequirement += liquidationMarginRequirementExposureUpper;
                highestUnrealizedLoss += exposureUpper.unrealizedLoss;
            }
        }
    }

    function computeLMAndHighestUnrealizedLossFromLowerAndUpperExposuresAllCollaterals(
        Exposure[] memory exposuresLower,
        Exposure[] memory exposuresUpper
    ) internal view
    returns (uint256 liquidationMarginRequirementInUSD, uint256 highestUnrealizedLossInUSD)
    {

        require(exposuresLower.length == exposuresUpper.length);

        for (uint256 i=0; i < exposuresLower.length; i++) {
            require(exposuresLower[i].productId == exposuresUpper[i].productId);
            require(exposuresLower[i].marketId == exposuresUpper[i].marketId);
            require(exposuresLower[i].collateralType == exposuresUpper[i].collateralType);
            Exposure memory exposureLower = exposuresLower[i];
            Exposure memory exposureUpper = exposuresUpper[i];
            UD60x18 collateralPriceInUSD = CollateralConfiguration.load(exposureLower.collateralType)
            .getCollateralPrice();
            UD60x18 riskParameter = getRiskParameter(exposureLower.productId, exposureLower.marketId);
            uint256 liquidationMarginRequirementExposureLower =
            computeLiquidationMarginRequirement(exposureLower.annualizedNotional, riskParameter);
            uint256 liquidationMarginRequirementExposureUpper =
            computeLiquidationMarginRequirement(exposureUpper.annualizedNotional, riskParameter);

            if (
                liquidationMarginRequirementExposureLower + exposureLower.unrealizedLoss >
                liquidationMarginRequirementExposureUpper + exposureUpper.unrealizedLoss
            ) {
                liquidationMarginRequirementInUSD += mulUDxUint(collateralPriceInUSD,
                    liquidationMarginRequirementExposureLower);
                highestUnrealizedLossInUSD += mulUDxUint(collateralPriceInUSD, exposureLower.unrealizedLoss);
            } else {
                liquidationMarginRequirementInUSD += mulUDxUint(collateralPriceInUSD,
                    liquidationMarginRequirementExposureUpper);
                highestUnrealizedLossInUSD += mulUDxUint(collateralPriceInUSD, exposureUpper.unrealizedLoss);
            }
        }
    }


    /**
    * @dev Returns the liquidation margin requirement and unrealized loss given a set of taker exposures
     */
    function computeLMAndUnrealizedLossFromExposures(Exposure[] memory exposures)
    internal
    view
    returns (uint256 liquidationMarginRequirement, uint256 unrealizedLoss)
    {
        for (uint256 i=0; i < exposures.length; i++) {
            Exposure memory exposure = exposures[i];
            UD60x18 riskParameter = getRiskParameter(exposure.productId, exposure.marketId);
            uint256 liquidationMarginRequirementExposure =
            computeLiquidationMarginRequirement(exposure.annualizedNotional, riskParameter);
            liquidationMarginRequirement += liquidationMarginRequirementExposure;
            unrealizedLoss += exposure.unrealizedLoss;
        }

    }

    /**
     * @dev Returns the liquidation margin requirement and unrealized loss given a set of taker exposures
     * with varying collateral types and computes the result in USD
     */
    function computeLMAndUnrealizedLossFromExposuresAllCollaterals(Exposure[] memory exposures)
    internal
    view
    returns (uint256 liquidationMarginRequirementInUSD, uint256 unrealizedLossInUSD)
    {
        for (uint256 i=0; i < exposures.length; i++) {
            Exposure memory exposure = exposures[i];
            UD60x18 collateralPriceInUSD = CollateralConfiguration.load(exposure.collateralType).getCollateralPrice();
            UD60x18 riskParameter = getRiskParameter(exposure.productId, exposure.marketId);
            uint256 liquidationMarginRequirementExposure =
            computeLiquidationMarginRequirement(exposure.annualizedNotional, riskParameter);
            liquidationMarginRequirementInUSD += mulUDxUint(collateralPriceInUSD, liquidationMarginRequirementExposure);
            unrealizedLossInUSD += mulUDxUint(collateralPriceInUSD, exposure.unrealizedLoss);
        }
    }

    function getWeightedCollateralBalanceInUSD(Data storage self) internal view
    returns (uint256 weightedCollateralBalanceInUSD) {
        // todo: consider breaking this function into a combination of a pure + view function (CR)
        SetUtil.AddressSet storage _activeCollateralTokenAddresses = self.activeCollateralTokenAddresses;
        for (uint256 i = 1; i <= _activeCollateralTokenAddresses.length(); i++) {
            address collateralTokenAddress = _activeCollateralTokenAddresses.valueAt(i);
            uint256 collateralBalance = self.getCollateralBalance(collateralTokenAddress);
            CollateralConfiguration.Data storage collateralConfiguration = CollateralConfiguration.load(collateralTokenAddress);
            uint256 collateralBalanceInUSD = mulUDxUint(collateralConfiguration.getCollateralPrice(), collateralBalance);
            uint256 collateralBalanceInUSDWithHaircut = mulUDxUint(collateralConfiguration.weight, collateralBalanceInUSD);
            weightedCollateralBalanceInUSD += collateralBalanceInUSDWithHaircut;
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


}
