/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import { OracleManager } from  "./OracleManager.sol";

import { INodeModule } from "@voltz-protocol/oracle-manager/src/interfaces/INodeModule.sol";
import {CollateralPool} from  "./CollateralPool.sol";
import {GlobalCollateralConfiguration} from  "./GlobalCollateralConfiguration.sol";

import { NodeOutput } from "@voltz-protocol/oracle-manager/src/storage/NodeOutput.sol";
import { IERC20 } from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";
import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";

import { SafeCastI256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18, ZERO, UNIT } from "@prb/math/UD60x18.sol";
import { mulUDxUint } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

library CollateralConfiguration {
    using CollateralConfiguration for CollateralConfiguration.Data;
    using CollateralPool for CollateralPool.Data;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastI256 for int256;
    using GlobalCollateralConfiguration for GlobalCollateralConfiguration.Data;

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

    /**
     * @dev Thrown when the withdraw limit was reached for a collateral type.
     */
    error CollateralTypeWithdrawLimitReached(address collateralType, uint32 windowStartTimestamp);

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
         * @dev Time window in seconds in which the withdraw limit is applied
         */
        uint32 withdrawalWindowSize;

        /**
         * @dev Percentage of tvl that is allowed to be withdrawn in one time window
         */
        UD60x18 withdrawalTvlPercentageLimit;

        /**
         * @dev Auto-exchange occurs when an account has a negative balance for one collateral asset in token terms
         * is below the single autoExchangeThreshold of the token e.g. 5000 USDC
         */
        uint256 autoExchangeThreshold;

        /**
         * @dev Percentage of quote tokens paid to the insurance fund
         * @dev at auto-exchange. (e.g. 0.1 * 1e18 = 10%)
         */
        UD60x18 autoExchangeInsuranceFee;

        /**
         * @dev When performing within bubble exhaustion checks, this value acts as a threshold that considers the
         * amount dust
         */
        uint256 autoExchangeDustThreshold;

        /**
         * @dev Flat fee transferred from liquidator to IF when a liquidation bid is submitted
         */
        uint256 bidSubmissionFee;

        /**
         * @dev Flat fee that is awarded to the keeper for adl propagations, taken from IF
         */
        uint256 adlPropagationKeeperFee;

        /**
         * @dev Minimum funds threshold that must be left in insurance fund
         * for covering keeper rewards for adl propagation.
         */
        uint256 minInsuranceFundThreshold;
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
         * @dev Total value of withdrawals in the current window
         */
        uint256 windowWithdrawals;
    
        /**
         * @dev Unix timestamp of the latest cached withdraw period start
         */
        uint32 windowStartTimestamp;
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
        UD60x18 priceHaircut;

        /**
         * @dev Auto-exchange discount (in wad)
         */
        UD60x18 autoExchangeDiscount;

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
        UD60x18 priceHaircut;
        UD60x18 autoExchangeDiscount;
    }

    /**
     * @dev Loads the Configuration object for the given collateral type in the given collateral pool.
     * @param collateralPoolId The collateral pool id.
     * @param token The address of the collateral type.
     * @return collateralConfiguration The Configuration object.
     */
    function load(uint128 collateralPoolId, address token) internal pure returns (Data storage collateralConfiguration) {
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
        GlobalCollateralConfiguration.exists(tokenAddress);

        Data storage storedConfig = load(collateralPoolId, tokenAddress);

        storedConfig.baseConfig = config;
        
        storedConfig.cachedConfig = CachedConfiguration({
            collateralPoolId: collateralPoolId,
            tokenAddress: tokenAddress,
            set: true,
            windowWithdrawals: 0,
            windowStartTimestamp: 0
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

    function combineDiscounts(UD60x18 a, UD60x18 b) private pure returns (UD60x18) {
        return UNIT.sub((UNIT.sub(a)).mul(UNIT.sub(b)));
    }

    function computeExchangeUpwards(uint128 collateralPoolId, address node, address ancestor) 
        private
        view 
        returns (ExchangeInfo memory exchange) 
    {
        address current = node;
        exchange.price = UNIT;
        exchange.priceHaircut = ZERO;
        exchange.autoExchangeDiscount = ZERO;
    
        while (true) {
            if (current == ancestor) {
                break;
            }

            Data storage currentConfig = load(collateralPoolId, current);

            if (!currentConfig.parentConfig.hasParent) {
                revert UnlinkedTokens(collateralPoolId, node, ancestor);
            }

            exchange.priceHaircut = combineDiscounts(exchange.priceHaircut, currentConfig.parentConfig.priceHaircut);
            exchange.autoExchangeDiscount = 
                combineDiscounts(exchange.autoExchangeDiscount, currentConfig.parentConfig.autoExchangeDiscount);
            
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
            priceHaircut: combineDiscounts(exchangeA.priceHaircut, exchangeB.priceHaircut),
            autoExchangeDiscount: combineDiscounts(exchangeA.autoExchangeDiscount, exchangeB.autoExchangeDiscount)
        });
    }

    /**
     * @dev Updates the withdraw limit trackers and checks if limit was reached
     */
    function checkWithdrawLimits(Data storage self, uint256 shares) internal {
        address tokenAddress = self.cachedConfig.tokenAddress;
        uint32 timestamp = Time.blockTimestampTruncated();

        CollateralPool.Data storage collateralPool = CollateralPool.exists(self.cachedConfig.collateralPoolId);
        GlobalCollateralConfiguration.Data storage globalConfig = GlobalCollateralConfiguration.exists(tokenAddress);
    
        bool isNewWindow = timestamp > 
            self.cachedConfig.windowStartTimestamp + self.baseConfig.withdrawalWindowSize;
        
        if (isNewWindow) {
            self.cachedConfig.windowStartTimestamp = timestamp;
            self.cachedConfig.windowWithdrawals = 0;
        }

        uint256 assets = globalConfig.convertToAssets(shares);
        self.cachedConfig.windowWithdrawals += assets;

        // check withdraw limits against tvl
        uint256 tvl = collateralPool.getCollateralBalance(tokenAddress);

        if ( 
            self.cachedConfig.windowWithdrawals > 
            mulUDxUint(self.baseConfig.withdrawalTvlPercentageLimit, tvl)
        ) {
            revert CollateralTypeWithdrawLimitReached(tokenAddress, self.cachedConfig.windowStartTimestamp);
        }

        globalConfig.checkWithdrawLimits(assets);
    }
}
