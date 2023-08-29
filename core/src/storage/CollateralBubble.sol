/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { Account } from  "./Account.sol";
import { OracleManager } from  "./OracleManager.sol";

import { INodeModule } from "@voltz-protocol/oracle-manager/src/interfaces/INodeModule.sol";
import { NodeOutput } from "@voltz-protocol/oracle-manager/src/storage/NodeOutput.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import { SafeCastI256, SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";
import { UD60x18, UNIT } from "@prb/math/UD60x18.sol";

library CollateralConfiguration {
    using Account for Account.Data;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

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
    error CannotExchangeTokens(uint128 collateralPoolId, address token, address baseToken);

    /**
     * @dev Thrown when collateral is not configured
     * @param collateralPoolId The id of the collateral pool.
     * @param collateralType The address of the collateral type.
     */
    error CollateralNotConfigured(uint128 collateralPoolId, address collateralType);

    struct Configuration {
        /**
         * @dev Allows the owner to control deposits and delegation of collateral types.
         */
        bool depositingEnabled;

        /**
         * @dev Cap which limits the amount of tokens that can be deposited.
         */
        uint256 cap;

        /**
         * @dev The oracle manager node id which reports the current price for this collateral type wrt the parent token.
         */
        bytes32 oracleNodeId;
    }

    struct CachedConfiguration {
        /**
         * @dev Flag that shows if the configuration is set or not.
         */
        bool set;

        /**
         * @dev The token address for this collateral type.
         */
        address tokenAddress;

        /**
         * @dev The token decimals for this collateral type.
         * @notice If the address is ZERO_ADDRESS, it represents USD.
         */
        uint8 tokenDecimals;
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
         * @dev Percentage of tokens to award when the collateral asset is liquidated as part of the auto-exchange mechanic
         */
        UD60x18 autoExchangeDiscount;
    }

    struct Data {
        uint128 collateralPoolId;
        SetUtil.AddressSet childTokens;

        Configuration baseConfig;
        CachedConfiguration cachedConfig;

        ParentConfiguration parentConfig;
    }

    struct ExchangeInfo {
        address token;
        address baseToken;

        UD60x18 price;
        UD60x18 exchangeHaircut;
        UD60x18 autoExchangeDiscount;
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

        storedConfig.baseConfig.depositingEnabled = config.depositingEnabled;
        storedConfig.baseConfig.cap = config.cap;

        storedConfig.cachedConfig.tokenAddress = tokenAddress;
        uint8 tokenDecimals = IERC20(tokenAddress).decimals();
        storedConfig.cachedConfig.tokenDecimals = tokenDecimals;
        storedConfig.cachedConfig.set = true;

        emit CollateralConfigurationUpdated(storedConfig.baseConfig, storedConfig.parentConfig, block.timestamp);
    }

    /**
     * @dev Configures a collateral type.
     * @param config The Configuration object with all the settings for the collateral type being configured.
     */
    function setParentConfig(uint128 collateralPoolId, address tokenAddress, ParentConfiguration memory config) internal {
        Data storage storedConfig = exists(collateralPoolId, tokenAddress);

        if (storedConfig.parentConfig.hasParent) {
            Data storage parent = exists(collateralPoolId, storedConfig.parentConfig.tokenAddress);
            parent.childTokens.remove(tokenAddress);
        } 

        storedConfig.parentConfig = config;

        if (storedConfig.parentConfig.hasParent) {
            Data storage parent = exists(collateralPoolId, storedConfig.parentConfig.tokenAddress);
            parent.childTokens.add(tokenAddress);
        } 

        emit CollateralConfigurationUpdated(storedConfig.baseConfig, storedConfig.parentConfig, block.timestamp);
    }

    function getRootPath(uint128 collateralPoolId, address token) private view returns(address[] memory) {
        uint256 size = 0;
    
        while (true) {
            Data storage current = exists(collateralPoolId, token);
            size += 1;

            if (!current.parentConfig.hasParent) {
                break;
            }
        }

        address[] memory tokens = new address[](size);

        size = 0;
        while (true) {
            Data storage current = exists(collateralPoolId, token);
            tokens[size] = token;
            size += 1;

            if (!current.parentConfig.hasParent) {
                break;
            }
        }

        return tokens;
    }

    function getCommonToken(uint128 collateralPoolId, address tokenA, address tokenB) 
        private 
        view 
        returns (address) 
    {
        address[] memory pathA = getRootPath(collateralPoolId, tokenA);
        address[] memory pathB = getRootPath(collateralPoolId, tokenB);

        uint256 commonPoints = 1;

        while (
            commonPoints <= pathA.length && 
            commonPoints <= pathB.length && 
            pathA[pathA.length - commonPoints] == pathB[pathB.length - commonPoints]) 
        {
            commonPoints += 1;
        }
        
        return pathA[pathA.length + 1 - commonPoints];
    }

    function getExchangeInfo(uint128 collateralPoolId, address token, address baseToken) 
        internal
        view 
        returns (ExchangeInfo memory exchangeInfo) 
    {
        exchangeInfo.token = token;
        exchangeInfo.baseToken = baseToken;

        exchangeInfo.price = UNIT;
        exchangeInfo.exchangeHaircut = UNIT;
        exchangeInfo.autoExchangeDiscount = UNIT;
    
        while (true) {
            Data storage current = exists(collateralPoolId, token);

            if (!current.parentConfig.hasParent) {
                revert CannotExchangeTokens(collateralPoolId, token, baseToken);
            }

            address parentToken = current.parentConfig.tokenAddress;

            if (parentToken == baseToken) {
                break;
            }

            UD60x18 pairPrice = getCollateralPriceInToken(collateralPoolId, token, parentToken);

            exchangeInfo.price = exchangeInfo.price.mul(pairPrice);
            exchangeInfo.exchangeHaircut = exchangeInfo.exchangeHaircut.mul(current.parentConfig.exchangeHaircut);
            exchangeInfo.autoExchangeDiscount = exchangeInfo.autoExchangeDiscount.mul(current.parentConfig.autoExchangeDiscount);

            token = parentToken;
        }        
    }

    function getSubTokens(uint128 collateralPoolId, address baseToken)
        internal 
        view
        returns (ExchangeInfo[] memory) 
    {
        uint256 it = 1;
        address[] memory tokens = exists(collateralPoolId, baseToken).childTokens.values();
        ExchangeInfo[][] memory sub = new ExchangeInfo[][](tokens.length);

        for (uint256 i = 0; i < tokens.length; i++) {
            sub[i] = getSubTokens(collateralPoolId, tokens[i]);
            it += sub.length;
        }

        ExchangeInfo[] memory info = new ExchangeInfo[](it);

        info[0] = ExchangeInfo({
            token: baseToken,
            baseToken: baseToken,

            price: UNIT,
            exchangeHaircut: UNIT,
            autoExchangeDiscount: UNIT
        });

        it = 1;

        for (uint256 i = 0; i < tokens.length; i++) {
            Data storage token = exists(collateralPoolId, tokens[i]);

            UD60x18 pairPrice = getCollateralPriceInToken(collateralPoolId, token.cachedConfig.tokenAddress, baseToken);

            for (uint256 j = 0; j < sub[i].length; j++) {
                info[it] = ExchangeInfo({
                    token: sub[i][j].token,
                    baseToken: baseToken,

                    price: sub[i][j].price.mul(pairPrice),
                    exchangeHaircut: sub[i][j].exchangeHaircut.mul(token.parentConfig.exchangeHaircut),
                    autoExchangeDiscount: sub[i][j].autoExchangeDiscount.mul(token.parentConfig.autoExchangeDiscount)
                });

                it += 1;
            }
        }

        return info;
    }

    function getAutoExchangeAmount(uint128 collateralPoolId, address tokenA, address tokenB, uint256 amount) 
        internal
        view 
        returns(uint256 autoExchangeAmount) 
    {
        address baseToken = getCommonToken(collateralPoolId, tokenA, tokenB);

        ExchangeInfo memory exchangeInfoA = getExchangeInfo(collateralPoolId, tokenA, baseToken);
        ExchangeInfo memory exchangeInfoB = getExchangeInfo(collateralPoolId, tokenB, baseToken);

        return mulUDxUint(exchangeInfoA.autoExchangeDiscount.mul(exchangeInfoB.autoExchangeDiscount), amount);
    }

    /**
     * @dev Shows if a given collateral type is enabled for deposits and delegation.
     * @param collateralPoolId The id of the collateral pool being queried.
     * @param token The address of the collateral being queried.
     */
    function collateralEnabled(uint128 collateralPoolId, address token) internal view {
        if (!exists(collateralPoolId, token).baseConfig.depositingEnabled) {
            revert CollateralDepositDisabled(collateralPoolId, token);
        }
    }

    /**
     * @dev Returns the price of one collateral `token` in USD.
     * @return The price of the collateral with 18 decimals of precision.
     */
    function getCollateralPriceInUSD(uint128 collateralPoolId, address token) internal view returns (UD60x18) {
        if (token == address(0)) {
            return UNIT;
        }

        OracleManager.Data memory oracleManager = OracleManager.exists();
        NodeOutput.Data memory node = INodeModule(oracleManager.oracleManagerAddress).process(
            exists(collateralPoolId, token).baseConfig.oracleNodeId
        );

        return UD60x18.wrap(node.price.toUint());
    }

    /**
     * @dev Returns the price of one collateral `tokenA` in other collateral `tokenB`.
     * @return The price of the collateral with 18 decimals of precision.
     */
    function getCollateralPriceInToken(uint128 collateralPoolId, address tokenA, address tokenB) internal view returns (UD60x18) {
        UD60x18 priceA = getCollateralPriceInUSD(collateralPoolId, tokenA);
        UD60x18 priceB = getCollateralPriceInUSD(collateralPoolId, tokenB);

        return priceA.div(priceB);
    }
}
