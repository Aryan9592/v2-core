/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { OracleManager } from  "./OracleManager.sol";

import { INodeModule } from "@voltz-protocol/oracle-manager/src/interfaces/INodeModule.sol";
import { NodeOutput } from "@voltz-protocol/oracle-manager/src/storage/NodeOutput.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";

library CollateralConfiguration {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastI256 for int256;

    /**
     * @notice Emitted when a collateral type’s configuration is created or updated.
     * @param baseConfig The base configuration with the newly configured details.
     * @param parentConfig The parent configuration with the newly configured details.
     * @param blockTimestamp The current block timestamp.
     */
    event CollateralConfigurationUpdated(
        Configuration baseConfig, 
        ParentConfiguration parentConfig, 
        uint256 blockTimestamp
    );

    /**
     * @dev Thrown when deposits are disabled for the given collateral type.
     * @param collateralPoolId The id of the collateral pool.
     * @param collateralType The address of the collateral type for which depositing was disabled.
     */
    error CollateralDepositDisabled(uint128 collateralPoolId, address collateralType);

    /**
     * @dev Thrown when one collateral is attempted to be exchanged in a collateral that does not belong to its base tokens.
     * @param collateralPoolId The id of the collateral pool.
     * @param token The address of the collateral type that needs to be exchanged.
     * @param baseToken The base token of the exchange.
     */
    error UnlinkedTokens(uint128 collateralPoolId, address token, address baseToken);

    /**
     * @dev Thrown when collateral is not configured
     * @param collateralPoolId The id of the collateral pool.
     * @param collateralType The address of the collateral type.
     */
    error CollateralNotConfigured(uint128 collateralPoolId, address collateralType);

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
         * @dev Total value in the collateral pool
         */
        uint256 tvl;
        /**
         * @dev Total value of withdrawals in the current window
         */
        uint256 windowWithdrawals;
    }

    struct Configuration {
        /**
         * @dev Allows the owner to control deposits and delegation of collateral types.
         */
        bool depositingEnabled;

        /**
         * @dev Cap which limits the amount of tokens that can be deposited.
         */
        uint256 cap;
    }

    struct CachedConfiguration {
        /**
         * @dev Flag that shows if the configuration is set or not.
         */
        bool set;

        /**
         * @dev The collateral pool ID of this collateral configuration.
         */
        uint128 collateralPoolId;

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
         * @dev Withdraw limit configuration
         */
        WithdrawLimitsConfig withdrawLimitsConfig;
        /**
         * @dev Withdraw limit trackers
         */
        WithdrawLimitsTrackers withdrawLimitsTrackers;
    }

    struct ParentConfiguration {
        /**
         * @dev Flag that shows whether the collateral has parent or not.
         */
        bool hasParent;

        /**
         * @dev Token address of the collateral.
         * @notice If the address is ZERO_ADDRESS, it represents USD.
         */
        address tokenAddress;

        /**
         * @dev Collateral haircut factor (in wad) used in margin requirement calculations 
         * when determining the collateral value wrt the parent token.
         */
        UD60x18 exchangeHaircut;

        /**
         * @dev The oracle manager node id which reports the current price of this collateral in its parent colalteral.
         */
        bytes32 oracleNodeId;
    }

    struct Data {
        SetUtil.AddressSet childTokens;

        Configuration baseConfig;
        CachedConfiguration cachedConfig;

        ParentConfiguration parentConfig;
    }

    struct ExchangeInfo {
        UD60x18 price;
        UD60x18 haircut;
    }

    /**
     * @dev Loads the Configuration object for the given collateral type in the given collateral pool.
     * @param collateralPoolId The collateral pool id.
     * @param token The address of the collateral type.
     * @return collateralConfiguration The Configuration object.
     */
    function load(uint128 collateralPoolId, address token) private pure returns (Data storage collateralConfiguration) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Configuration", collateralPoolId, token));
        assembly {
            collateralConfiguration.slot := s
        }
    }

    /**
     * @dev Returns the collateral configuration
     * @param collateralPoolId The collateral pool id.
     * @param token The address of the collateral type
     */
    function exists(uint128 collateralPoolId, address token) internal view returns (Data storage collateralConfiguration) {
        collateralConfiguration = load(collateralPoolId, token);

        if (!collateralConfiguration.cachedConfig.set) {
            revert CollateralNotConfigured(collateralPoolId, token);
        }
    }

    /**
     * @dev Configures a collateral type.
     * @param config The Configuration object with all the settings for the collateral type being configured.
     */
    function setBaseConfig(uint128 collateralPoolId, address tokenAddress, Configuration memory config) internal {
        Data storage storedConfig = load(collateralPoolId, tokenAddress);

        storedConfig.baseConfig = config;
        
        storedConfig.cachedConfig = CachedConfiguration({
            collateralPoolId: collateralPoolId,
            tokenAddress: tokenAddress,
            tokenDecimals: IERC20(tokenAddress).decimals(),
            set: true
        });

        emit CollateralConfigurationUpdated(storedConfig.baseConfig, storedConfig.parentConfig, block.timestamp);
    }

    /**
     * @dev Configures a collateral type.
     * @param config The Configuration object with all the settings for the collateral type being configured.
     */
    function setParentConfig(uint128 collateralPoolId, address tokenAddress, ParentConfiguration memory config) internal {
        Data storage storedConfig = exists(collateralPoolId, tokenAddress);

        if (storedConfig.parentConfig.hasParent) {
            address parentToken = storedConfig.parentConfig.tokenAddress;
            load(collateralPoolId, parentToken).childTokens.remove(tokenAddress);
        } 

        // todo: add propgramatic check against new parent being the token itself or any of its children
        storedConfig.parentConfig = config;

        if (storedConfig.parentConfig.hasParent) {
            address parentToken = storedConfig.parentConfig.tokenAddress;
            load(collateralPoolId, parentToken).childTokens.add(tokenAddress);
        } 

        emit CollateralConfigurationUpdated(storedConfig.baseConfig, storedConfig.parentConfig, block.timestamp);
    }

    /**
     * @dev Shows if a given collateral type is enabled for deposits and delegation.
     * @param collateralPoolId The id of the collateral pool being queried.
     * @param token The address of the collateral being queried.
     */
    function collateralEnabled(uint128 collateralPoolId, address token) internal view {
        if (!load(collateralPoolId, token).baseConfig.depositingEnabled) {
            revert CollateralDepositDisabled(collateralPoolId, token);
        }
    }

    function getHeight(uint128 collateralPoolId, address token) private view returns(uint256 height) {
        address current = token;
        height = 0;

        while (true) {
            Data storage currentConfig = load(collateralPoolId, current);

            if (!currentConfig.parentConfig.hasParent) {
                break;
            }

            height += 1;
            current = currentConfig.parentConfig.tokenAddress;
        }

        return height;
    }

    function getCommonToken(uint128 collateralPoolId, address tokenA, address tokenB) 
        private 
        view 
        returns (address) 
    {
        uint256 heightA = getHeight(collateralPoolId, tokenA);
        uint256 heightB = getHeight(collateralPoolId, tokenB);

        while (true) {
            if (tokenA == tokenB) {
                return tokenA;
            }

            if (heightA == 0 && heightB == 0) {
                break;
            }

            if (heightA >= heightB) {
                tokenA = load(collateralPoolId, tokenA).parentConfig.tokenAddress;
                heightA -= 1;
            }

            if (heightA < heightB) {
                tokenB = load(collateralPoolId, tokenB).parentConfig.tokenAddress;
                heightB -= 1;
            }
        }

        revert UnlinkedTokens(collateralPoolId, tokenA, tokenB);
    }

    function computeExchangeUpwards(uint128 collateralPoolId, address node, address ancestor) 
        private
        view 
        returns (ExchangeInfo memory exchange) 
    {
        address current = node;
        exchange.price = UNIT;
        exchange.haircut = UNIT;
    
        while (true) {
            if (current == ancestor) {
                break;
            }

            Data storage currentConfig = load(collateralPoolId, current);

            if (!currentConfig.parentConfig.hasParent) {
                revert UnlinkedTokens(collateralPoolId, node, ancestor);
            }

            exchange.haircut = exchange.haircut.mul(currentConfig.parentConfig.exchangeHaircut);
            exchange.price = exchange.price.mul(getParentPrice(currentConfig));

            current = currentConfig.parentConfig.tokenAddress;
        }        
    }
    
    function getParentPrice(Data storage config) internal view returns (UD60x18) {
        OracleManager.Data memory oracleManager = OracleManager.exists();
    
        NodeOutput.Data memory node = INodeModule(oracleManager.oracleManagerAddress).process(
            config.parentConfig.oracleNodeId
        );

        return UD60x18.wrap(node.price.toUint());
    }

    /**
     * @dev Returns the price of one collateral `tokenA` in other collateral `tokenB`.
     * @return The price of the collateral with 18 decimals of precision.
     */
    function getExchangeInfo(uint128 collateralPoolId, address tokenA, address tokenB) internal view returns (ExchangeInfo memory) {
        address commonToken = getCommonToken(collateralPoolId, tokenA, tokenB);

        ExchangeInfo memory exchangeA = computeExchangeUpwards(collateralPoolId, tokenA, commonToken);
        ExchangeInfo memory exchangeB = computeExchangeUpwards(collateralPoolId, tokenB, commonToken);

        return ExchangeInfo({
            price: exchangeA.price.div(exchangeB.price),
            haircut: exchangeA.haircut.mul(exchangeB.haircut)
        });
    }
}
