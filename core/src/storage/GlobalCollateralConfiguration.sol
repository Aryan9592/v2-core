/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
//mport {TokenAdapter} from  "./TokenAdapter.sol";
//import {CollateralPool} from  "./CollateralPool.sol";
//import {GlobalCollateralConfiguration} from  "./GlobalCollateralConfiguration.sol";
import {ITokenAdapterModule} from "../interfaces/ITokenAdapterModule.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { IERC165 } from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library GlobalCollateralConfiguration {

    /**
     * @notice Emitted when the withdraw limits for a collateral token are created or updated
     */
    event GlobalCollateralConfigurationUpdated(
        address collateralType,
        WithdrawLimitsConfig withdrawLimitsConfig,
        address trustedTokenAdapterAddress,
        uint256 blockTimestamp
    );

    /**
     * @dev Thrown when collateral pool withdraw limit is reached
     */
    error GlobalWithdrawLimitReached(address collateralType);

    /**
     * @dev Thrown when collateral type created with ZERO address
     */
    error GlobalCollateralCannotBeZero();

    /**
     * @dev Thrown when global collateral was not found
     */
    error GlobalCollateralNotFound(address collateralType);

    /**
     * @dev Thrown when collateral type was already created
     */
    error GlobalCollateralAlreadyExists(address collateralType);

    /**
     * @dev Thrown when the given token adapter address does not support the right interface
     */
    error IncorrectTokenAdapter(address trustedTokenAdapterAddress);

    struct WithdrawLimitsConfig {
        /**
         * @dev Time window in seconds in which the withdraw limit is applied
         */
        uint32 withdrawalWindowSize;

        /**
         * @dev Percentage of tvl that is allowed to be withdrawn in one time window
         */
        UD60x18 withdrawalTvlPercentageLimit;
    }

    struct WithdrawLimitsTrackers {
        /**
         * @dev Total value of withdrawals in the current window
         */
        uint256 windowWithdrawals;
         /**
         * @dev Protocol wide shares in collateral type
         */
        uint32 sharesTvl;
    }

    struct Data {
        address collateralType;
        /**
         * @dev Mapping from collateral type to withdraw limit configuration
         */
        WithdrawLimitsConfig withdrawLimitsConfig;
        /**
         * @dev Mapping from collateral type to withdraw limit trackers
         */
        WithdrawLimitsTrackers withdrawLimitsTrackers;
        /**
         * @dev Trusted token adapter for this collateral type
         */
        address trustedTokenAdapterAddress;

    }

    /**
     * @dev Creates an collateral pool for the given id
     */
    function create(
        address collateralType,
        WithdrawLimitsConfig memory withdrawLimitsConfig, 
        address trustedTokenAdapterAddress
    ) internal returns(Data storage globalCollateral) {
        if (collateralType == address(0)) {
            revert GlobalCollateralCannotBeZero();
        }

        globalCollateral = load(collateralType);
        
        if (globalCollateral.collateralType != address(0)) {
            revert GlobalCollateralAlreadyExists(collateralType);
        }

        globalCollateral.collateralType = collateralType;
        globalCollateral.trustedTokenAdapterAddress = trustedTokenAdapterAddress;
        globalCollateral.withdrawLimitsConfig = withdrawLimitsConfig;

        emit GlobalCollateralConfigurationUpdated(
            globalCollateral.collateralType,
            globalCollateral.withdrawLimitsConfig,
            globalCollateral.trustedTokenAdapterAddress,
            block.timestamp
        );
    }

    /**
     * @dev Configures a collateral type.
     * @param config The Configuration object with all the settings for the collateral type being configured.
     */
    function setConfig(
        address collateralType,
        WithdrawLimitsConfig memory config,
        address trustedTokenAdapterAddress
    ) internal {
        Data storage storedConfig = load(collateralType);

        // todo: check new window size & limit & trusted 
        storedConfig.withdrawLimitsConfig = config;

        if (
            !IERC165(trustedTokenAdapterAddress)
            .supportsInterface(type(ITokenAdapterModule).interfaceId)
        ) {
            revert IncorrectTokenAdapter(trustedTokenAdapterAddress);
        }
        storedConfig.trustedTokenAdapterAddress = trustedTokenAdapterAddress;


        emit GlobalCollateralConfigurationUpdated(
            storedConfig.collateralType,
            storedConfig.withdrawLimitsConfig,
            storedConfig.trustedTokenAdapterAddress,
            block.timestamp
        );
    }

    function exists(address collateralType) internal view returns (Data storage globalCollateral) {
        globalCollateral = load(collateralType);
    
        if (globalCollateral.collateralType == address(0)) {
            revert GlobalCollateralNotFound(collateralType);
        }
    }

    function doesExists(address collateralType) internal pure returns (bool) {
        Data memory globalCollateral = load(collateralType);
    
        return globalCollateral.collateralType != address(0);
    }

    /**
     * @dev Returns the collateral pool stored at the specified id.
     */
    function load(address collateralType) private pure returns (Data storage globalCollateral) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.GlobalCollateralConfiguration", collateralType));
        assembly {
            globalCollateral.slot := s
        }
    }

    /**
     * @dev Updates the withdraw limit trackers and checks if limit was reached
     */
    function checkWithdrawLimits(Data storage self, uint256 shares, bool isNewWindow) internal {
        uint256 windowWithdrawals = self.withdrawLimitsTrackers.windowWithdrawals;
        address collateralType = self.collateralType;

        // reset tracker if window has expired
        if (isNewWindow) {
            windowWithdrawals = 0;
        }

        // track window withdrawals
        ITokenAdapterModule tokenAdapter = ITokenAdapterModule(self.trustedTokenAdapterAddress);
        windowWithdrawals += tokenAdapter.convertToAssets(collateralType, shares);

        // check withdraw limits against tvl
        uint256 tvl = IERC20(collateralType).balanceOf(address(this));
        if ( 
            windowWithdrawals > 
            mulUDxUint(self.withdrawLimitsConfig.withdrawalTvlPercentageLimit, tvl)
        ) {
            revert GlobalWithdrawLimitReached(collateralType);
        }

        self.withdrawLimitsTrackers.windowWithdrawals = windowWithdrawals;
    }
}