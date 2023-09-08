/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/

pragma solidity >=0.8.19;

import { mulUDxUint, UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { ITokenAdapter } from "../interfaces/ITokenAdapter.sol";

import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { IERC165 } from "@voltz-protocol/util-contracts/src/interfaces/IERC165.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

/**
 * @title Object for tracking aggregate collateral pool balances
 */
library GlobalCollateralConfiguration {
    using GlobalCollateralConfiguration for GlobalCollateralConfiguration.Data;

    /**
     * @notice Emitted when the withdraw limits for a collateral are created or updated
     */
    event GlobalCollateralConfigurationUpdated(
        Data config,
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
     * @dev Thrown when the given token adapter address does not support the right interface
     */
    error IncorrectTokenAdapter(address tokenAdapterAddress);

    struct Configuration {
        /**
         * @dev Converts assets:shares and shares:assets for the given collateral.
         */
        address tokenAdapter;

        /**
         * @dev Time window in seconds in which the withdraw limit is applied
         */
        uint32 withdrawalWindowSize;

        /**
         * @dev Percentage of tvl that is allowed to be withdrawn in one time window
         */
        UD60x18 withdrawalTvlPercentageLimit;
    }

    struct CachedConfiguration {
        /**
         * @dev The token address for this collateral configuration.
         */
        address tokenAddress;

        /**
         * @dev The token decimals for this collateral type.
         * @notice If the address is ZERO_ADDRESS, it represents USD.
         */
        uint8 tokenDecimals;

        /**
         * @dev Total value of withdrawals in the current window
         */
        uint256 windowWithdrawals;
    
        /**
         * @dev Unix timestamp of the latest cached withdraw period start
         */
        uint32 windowStartTimestamp;
    }

    struct Data {
        Configuration config;

        CachedConfiguration cachedConfig;
    }

    /**
     * @dev Set configuration for one given collateral
     */
    function set(
        address tokenAddress,
        Configuration memory config
    ) internal returns(Data storage storedConfig) {
        if (tokenAddress == address(0)) {
            revert GlobalCollateralCannotBeZero();
        }

        storedConfig = load(tokenAddress);

        if (
            !IERC165(config.tokenAdapter)
            .supportsInterface(type(ITokenAdapter).interfaceId)
        ) {
            revert IncorrectTokenAdapter(config.tokenAdapter);
        }

        storedConfig.config = config;
        storedConfig.cachedConfig = CachedConfiguration({
            tokenAddress: tokenAddress,
            tokenDecimals: IERC20(tokenAddress).decimals(),
            windowWithdrawals: 0,
            windowStartTimestamp: 0
        });

        emit GlobalCollateralConfigurationUpdated(storedConfig, block.timestamp);
    }

    function exists(address collateralType) internal view returns (Data storage globalCollateral) {
        globalCollateral = load(collateralType);
    
        if (globalCollateral.cachedConfig.tokenAddress == address(0)) {
            revert GlobalCollateralNotFound(collateralType);
        }
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

    function convertToShares(Data storage self, uint256 assets) internal view returns (uint256) {
        return ITokenAdapter(self.config.tokenAdapter).convertToShares(assets);
    }

    function convertToAssets(Data storage self, uint256 shares) internal view returns (uint256) {
        return ITokenAdapter(self.config.tokenAdapter).convertToAssets(shares);
    }

    /**
     * @dev Updates the withdraw limit trackers and checks if limit was reached
     */
    function checkWithdrawLimits(Data storage self, uint256 assets) internal {
        address tokenAddress = self.cachedConfig.tokenAddress;
        uint32 timestamp = Time.blockTimestampTruncated();
    
        bool isNewWindow = timestamp > 
            self.cachedConfig.windowStartTimestamp + self.config.withdrawalWindowSize;

        // reset tracker if window has expired
        if (isNewWindow) {
            self.cachedConfig.windowStartTimestamp = timestamp;
            self.cachedConfig.windowWithdrawals = 0;
        }

        // track window withdrawals
        self.cachedConfig.windowWithdrawals += assets;

        // check withdraw limits against tvl
        uint256 tvl = IERC20(tokenAddress).balanceOf(address(this));

        if ( 
            self.cachedConfig.windowWithdrawals > 
            mulUDxUint(self.config.withdrawalTvlPercentageLimit, tvl)
        ) {
            revert GlobalWithdrawLimitReached(tokenAddress);
        }
    }
}