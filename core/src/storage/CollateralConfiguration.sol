/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/oracle-manager/src/interfaces/INodeModule.sol";
import "@voltz-protocol/oracle-manager/src/storage/NodeOutput.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "./OracleManager.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

import { mulUDxUint, divUintUDx } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

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

    struct Data {
        /**
         * @dev Allows the owner to control deposits and delegation of collateral types.
         */
        bool depositingEnabled;

        /**
         * @dev The token address for this collateral type.
         */
        address tokenAddress;
        
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
         * @dev Amount of tokens to award when the collateral asset is liquidated as part of the auto-exchange mechanic
         */
        UD60x18 autoExchangeReward;
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
    function set(Data memory config) internal {
        SetUtil.AddressSet storage collateralTypes = loadAvailableCollaterals();

        if (!collateralTypes.contains(config.tokenAddress)) {
            collateralTypes.add(config.tokenAddress);
        }

        Data storage storedConfig = load(config.tokenAddress);

        storedConfig.tokenAddress = config.tokenAddress;
        storedConfig.depositingEnabled = config.depositingEnabled;
        storedConfig.cap = config.cap;
        storedConfig.oracleNodeId = config.oracleNodeId;
        storedConfig.weight = config.weight;
        storedConfig.autoExchangeReward = config.autoExchangeReward;

        emit CollateralConfigurationUpdated(config, block.timestamp);
    }

    /**
     * @dev Shows if a given collateral type is enabled for deposits and delegation.
     * @param token The address of the collateral being queried.
     */
    function collateralEnabled(address token) internal view {
        if (!load(token).depositingEnabled) {
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
            self.oracleNodeId
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
        uint256 collateralBalanceInUSD = mulUDxUint(self.getCollateralPriceInUSD(), collateralAmount);

        return collateralBalanceInUSD;
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
        uint256 collateralBalanceInUSDWithHaircut = 
            mulUDxUint(self.weight, self.getCollateralInUSD(collateralAmount));

        return collateralBalanceInUSDWithHaircut;
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
        uint256 collateralAmount = divUintUDx(usdAmount, self.getCollateralPriceInUSD());
        
        return collateralAmount;
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
        uint256 usdAmount = divUintUDx(weightedUsdAmount, self.weight);
        
        return self.getUSDInCollateral(usdAmount);
    }
}
