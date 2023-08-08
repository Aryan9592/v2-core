/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import "@voltz-protocol/oracle-manager/src/interfaces/INodeModule.sol";
import "@voltz-protocol/oracle-manager/src/storage/NodeOutput.sol";
import "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { mulUDxUint, divUintUDx } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

import "./OracleManager.sol";

/**
 * @title Tracks protocol-wide settings for each collateral type, as well as helper functions for it, such as retrieving its current
 * price from the oracle manager -> relevant for multi-collateral.
 */
library CollateralConfiguration {
    using SetUtil for SetUtil.AddressSet;
    using SafeCastI256 for int256;
    using CollateralConfiguration for CollateralConfiguration.Data;

    bytes32 private constant _SLOT_AVAILABLE_COLLATERALS =
        keccak256(abi.encode("xyz.voltz.CollateralConfiguration_availableCollaterals"));

    /**
     * @notice Emitted when a collateral type’s configuration is created or updated.
     * @param config The object with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event CollateralConfigurationUpdated(Data config, uint256 blockTimestamp);

    /**
     * @dev Thrown when deposits are disabled for the given collateral type.
     * @param collateralType The address of the collateral type for which depositing was disabled.
     */
    error CollateralDepositDisabled(address collateralType);

    struct Config {
        /**
         * @dev Allows the owner to control deposits and delegation of collateral types.
         */
        bool depositingEnabled;

        /**
         * @dev Cap which limits the amount of tokens that can be deposited.
         */
        uint256 cap;

        /**
         * @dev The oracle manager node id which reports the current price for this collateral type.
         */
        bytes32 oracleNodeId;

        /**
         * @dev Collateral haircut factor (in wad) used in margin requirement calculations when determining the collateral value
         */
        UD60x18 weight;

        /**
         * @dev Percentage of tokens to award when the collateral asset is liquidated as part of the auto-exchange mechanic
         */
        UD60x18 autoExchangeDiscount;
    }

    struct CachedConfig {
        /**
         * @dev The token address for this collateral type.
         */
        address tokenAddress;

        /**
         * @dev The token decimals for this collateral type.
         */
        uint8 tokenDecimals;
    }

    struct Data {
        Config config;
        CachedConfig cachedConfig;
    }

    /**
     * @dev Loads the CollateralConfiguration object for the given collateral type.
     * @param token The address of the collateral type.
     * @return collateralConfiguration The CollateralConfiguration object.
     */
    function load(address token) internal pure returns (Data storage collateralConfiguration) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.CollateralConfiguration", token));
        assembly {
            collateralConfiguration.slot := s
        }
    }

    /**
     * @dev Loads all available collateral types configured in the protocol
     * @return availableCollaterals An array of addresses, one for each collateral type supported by the protocol
     */
    function loadAvailableCollaterals() internal pure returns (SetUtil.AddressSet storage availableCollaterals) {
        bytes32 s = _SLOT_AVAILABLE_COLLATERALS;
        assembly {
            availableCollaterals.slot := s
        }
    }

    /**
     * @dev Configures a collateral type.
     * @param config The CollateralConfiguration object with all the settings for the collateral type being configured.
     */
    function set(address tokenAddress, Config memory config) internal {
        SetUtil.AddressSet storage collateralTypes = loadAvailableCollaterals();

        if (!collateralTypes.contains(tokenAddress)) {
            collateralTypes.add(tokenAddress);
        }

        Data storage storedConfig = load(tokenAddress);

        storedConfig.config.depositingEnabled = config.depositingEnabled;
        storedConfig.config.cap = config.cap;
        storedConfig.config.oracleNodeId = config.oracleNodeId;
        storedConfig.config.weight = config.weight;
        storedConfig.config.autoExchangeReward = config.autoExchangeReward;

        storedConfig.cachedConfig.tokenAddress = tokenAddress;
        uint8 tokenDecimals = IERC20(tokenAddress).decimals();
        storedConfig.cachedConfig.tokenDecimals = tokenDecimals;

        emit CollateralConfigurationUpdated(storedConfig, block.timestamp);
    }

    /**
     * @dev Shows if a given collateral type is enabled for deposits and delegation.
     * @param token The address of the collateral being queried.
     */
    function collateralEnabled(address token) internal view {
        if (!load(token).config.depositingEnabled) {
            revert CollateralDepositDisabled(token);
        }
    }

    /**
     * @dev Returns the price of this collateral configuration object.
     * @param self The CollateralConfiguration object.
     * @return The price of the collateral with 18 decimals of precision.
     */
    function getCollateralPriceInUSD(Data storage self) internal view returns (UD60x18) {
        OracleManager.Data memory oracleManager = OracleManager.load();
        NodeOutput.Data memory node = INodeModule(oracleManager.oracleManagerAddress).process(
            self.config.oracleNodeId
        );

        return UD60x18.wrap(node.price.toUint());
    }

    /**
     * @dev Returns the amount of colletaral in USD.
     * @param self The CollateralConfiguration object.
     * @param collateralAmount The amount of collateral.
     * @return The corresponding USD amount of the collateral with 18 decimals of precision.
     */
    function getCollateralInUSD(
        Data storage self,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        uint8 decimals = self.cachedConfig.tokenDecimals;

        uint256 collateralAmountWad = changeDecimals(collateralAmount, decimals, 18);
        return mulUDxUint(self.getCollateralPriceInUSD(), collateralAmountWad);
    }

    /**
     * @dev Returns the weighted amount of colletaral in USD.
     * @param self The CollateralConfiguration object.
     * @param collateralAmount The amount of collateral.
     * @return The corresponding weighted USD amount of the collateral with 18 decimals of precision.
     */
    function getWeightedCollateralInUSD(
        Data storage self,
        uint256 collateralAmount
    ) internal view returns (uint256) {
        return mulUDxUint(self.config.weight, self.getCollateralInUSD(collateralAmount));
    }

    /**
     * @dev Returns the amount of USD in collateral.
     * @param self The CollateralConfiguration object.
     * @param usdAmount The amount of USD.
     * @return The corresponding amount of the collateral with 18 decimals of precision.
     */
    function getUSDInCollateral(
        Data storage self,
        uint256 usdAmount
    ) internal view returns (uint256) {
        uint8 decimals = self.cachedConfig.tokenDecimals;

        uint256 collateralAmountWad = divUintUDx(usdAmount, self.getCollateralPriceInUSD());
        return changeDecimals(collateralAmountWad, 18, decimals);
    }

    /**
     * @dev Returns the weighted amount of USD in collateral.
     * @param self The CollateralConfiguration object.
     * @param weightedUsdAmount The amount of USD.
     * @return The corresponding amount of the collateral with 18 decimals of precision.
     */
    function getWeightedUSDInCollateral(
        Data storage self,
        uint256 weightedUsdAmount
    ) internal view returns (uint256) {
        return divUintUDx(self.getUSDInCollateral(weightedUsdAmount), self.config.weight);
    }

    function changeDecimals(uint256 a, uint8 fromDecimals, uint8 toDecimals) internal pure returns(uint256) {
        if (fromDecimals < toDecimals) {
            return DecimalMath.upscale(a, toDecimals - fromDecimals);
        }

        if (fromDecimals > toDecimals) {
            // todo: think of precision loss (e.g. revert, emit event or do nothing)

            return DecimalMath.downscale(a, fromDecimals - toDecimals);
        }

        return a;
    }
}
