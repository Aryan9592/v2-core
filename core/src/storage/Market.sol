/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/errors/AccessError.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

import "./Account.sol";
import "./CollateralPool.sol";
import "./MarketStore.sol";
import "../interfaces/external/IMarketManager.sol";

/**
 * @title Connects external contracts that implement the `IMarketManager` interface to the protocol.
 *
 */
library Market {
    using Account for Account.Data;

    /**
     * @notice Emitted when a market is created or updated
     * @param market The object with the newly updated details.
     * @param blockTimestamp The current block timestamp.
     */
    event MarketUpdated(Market.Data market, uint256 blockTimestamp);

    /**
     * @dev Thrown when a market cannot be found.
     */
    error MarketNotFound(uint128 marketId);

    struct FeeConfiguration {
        /**
         * @dev Atomic Maker Fee is multiplied by the annualised notional liquidity provided via an on-chain exchange
         * @dev to derive the maker fee charged by the protocol.
         */
        UD60x18 atomicMakerFee;
        /**
         * @dev Atomic Taker Fee is multiplied by the annualised notional traded
         * @dev to derive the taker fee charged by the protocol.
         */
        UD60x18 atomicTakerFee;
    }

    struct Data {
        /**
         * @dev Numeric identifier for the market. Must be unique.
         * @dev There cannot be a market with id zero (See MarketCreator.create()). Id zero is used as a null market reference.
         */
        uint128 id;

        /**
         * @dev Address of the market's quote token. Must match the quote token address in the external
         * `IMarketManager` contract.
         */
        address quoteToken;

        /**
         * @dev Address for the external contract that implements the `IMarketManager` interface, 
         * which this Market objects connects to.
         *
         * Note: This object is how the system tracks the market. The actual market is external to the system, i.e. its own
         * contract.
         */
        address marketManagerAddress;
        /**
         * @dev Text identifier for the market.
         *
         * Not required to be unique.
         */
        string name;
        /**
         * @dev Market fee configurations for collateral pool
         */
        FeeConfiguration collateralPoolFeeConfig;
        /**
         * @dev Market fee configurations for insurance fund
         */
        FeeConfiguration insuranceFundFeeConfig;
        /**
         * @dev Market fee configurations for protocol
         */
        FeeConfiguration protocolFeeConfig;
        /**
         * @dev Address of fee collector
         */
        uint128 protocolFeeCollectorAccountId;

        /**
         * @dev Id of the risk matrix which hosts the parameters for this market
         */
        uint256 riskBlockId;
    }

    /**
     * @dev Given an external contract address representing an `IMarket`, creates a new id for the Market, and tracks it
     * internally in the protocol.
     *
     * The id used to track the Market will be automatically assigned by the protocol according to the last id used.
     *
     * Note: If an external `IMarket` contract tracks several Market ids, this function should be called for each Market it
     * tracks, resulting in multiple ids for the same address.
     * For example if a given Market works across maturities, each maturity internally will be represented as a unique Market id
     */
    function create(address marketManagerAddress, address quoteToken, string memory name, address owner)
        internal
        returns (Data storage market)
    {
        uint128 id = MarketStore.advanceMarketId();
        market = load(id);
    
        market.id = id;
        market.quoteToken = quoteToken;
        market.marketManagerAddress = marketManagerAddress;
        market.name = name;

        CollateralPool.create(id, owner);

        emit MarketUpdated(market, block.timestamp);
    }

    /**
     * @dev Returns the market stored at the specified market id.
     */
    function load(uint128 id) private pure returns (Data storage market) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Market", id));
        assembly {
            market.slot := s
        }
    }

    /**
     * @dev Returns the market stored at the specified market id.
     */
    function exists(uint128 id) internal view returns (Data storage market) {
        market = load(id);

        if (id == 0 || market.id != id) {
            revert MarketNotFound(id);
        }
    }

    /**
     * @dev Reverts if the caller is not the market address of the specified market
     */
    function onlyMarketAddress(uint128 marketId, address caller) internal view {
        if (Market.exists(marketId).marketManagerAddress != caller) {
            revert AccessError.Unauthorized(caller);
        }
    }

    /**
     * @dev Returns the root collateral pool of the market
     */
    function getCollateralPool(Data memory self) internal view returns (CollateralPool.Data storage) {
        return CollateralPool.getRoot(self.id);
    }

    /**
     * @dev Returns taker exposures alongside maker exposures for the lower and upper bounds of the maker's range
     * for a given collateralType
     */
    function getAccountTakerAndMakerExposures(Data storage self, uint128 accountId, uint256 riskMatrixDim)
        internal
        view
        returns (
        int256[] memory filledExposures,
        Account.UnfilledExposure[] memory unfilledExposures
    )
    {
        return IMarketManager(self.marketManagerAddress).getAccountTakerAndMakerExposures(
            self.id,
            accountId,
            riskMatrixDim
        );
    }

    function getAccountPnLComponents(Data storage self, uint128 accountId)
        internal
        view returns (Account.PnLComponents memory pnlComponents)
    {
        return IMarketManager(self.marketManagerAddress).getAccountPnLComponents(self.id, accountId);
    }

    /**
     * @dev Sets the protocol fee configuration for a given market
     * @param config The FeeConfiguration object with all the fee parameters
     */
    function setProtocolFeeConfiguration(Data storage self, FeeConfiguration memory config, uint128 accountId) internal {
        // check if fee collector account exists
        Account.exists(accountId);

        self.protocolFeeCollectorAccountId = accountId;
        self.protocolFeeConfig = config;

        emit MarketUpdated(self, block.timestamp);
    }

    /**
     * @dev Sets the insurance fund fee configuration for a given market
     * @param config The FeeConfiguration object with all the insurance fund fee parameters
     */
    function setInsuranceFundFeeConfiguration(Data storage self, FeeConfiguration memory config) internal {
        self.insuranceFundFeeConfig = config;

        emit MarketUpdated(self, block.timestamp);
    }

    // todo: add natspect and expose
    function setRiskBlockId(Data storage self, uint256 riskBlockId) internal {
        self.riskBlockId = riskBlockId;
        // todo add event
    }

    /**
     * @dev Sets the collateral pool fee configuration for a given market
     * @param config The FeeConfiguration object with all the fee parameters
     */
    function setCollateralPoolFeeConfiguration(Data storage self, FeeConfiguration memory config) internal {
        self.collateralPoolFeeConfig = config;

        emit MarketUpdated(self, block.timestamp);
    }

    /**
     * @dev The market at self.marketManagerAddress is expected to close all unfilled orders for all maturities and pools
     */
    function closeAllUnfilledOrders(Data storage self, uint128 accountId) internal {
        IMarketManager(self.marketManagerAddress).closeAllUnfilledOrders(self.id, accountId);
    }

    function hasUnfilledOrders(Data storage self, uint128 accountId) internal view returns (bool) {
        return IMarketManager(self.marketManagerAddress).hasUnfilledOrders(self.id, accountId);
    }

    function executeLiquidationOrder(
        Data storage self,
        uint128 liquidatableAccountId,
        uint128 liquidatorAccountId,
        bytes memory inputs
    ) internal {
        Account.exists(liquidatorAccountId).markActiveMarket(self.quoteToken, self.id);
        IMarketManager(self.marketManagerAddress).executeLiquidationOrder(
            liquidatableAccountId,
            liquidatorAccountId,
            self.id,
            inputs
        );
    }

    function validateLiquidationOrder(
        Data storage self,
        uint128 liquidatableAccountId,
        bytes memory inputs
    ) internal view {
        IMarketManager(self.marketManagerAddress).validateLiquidationOrder(
            liquidatableAccountId,
            self.id,
            inputs
        );
    }

    function getAnnualizedExposureWadAndPSlippage(
        Data storage self,
        uint128 marketId,
        bytes memory inputs
    ) internal view returns (int256 annualizedExposureWad, UD60x18 pSlippage) {
        return IMarketManager(self.marketManagerAddress).getAnnualizedExposureWadAndPSlippage(
            marketId,
            inputs
        );
    }


    function executeADLOrder(
        Data storage self,
        uint128 liquidatableAccountId,
        bool adlNegativeUpnl,
        bool adlPositiveUpnl,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    ) internal {
        IMarketManager(self.marketManagerAddress).executeADLOrder(
            liquidatableAccountId,
            self.id,
            adlNegativeUpnl,
            adlPositiveUpnl,
            totalUnrealizedLossQuote,
            realBalanceAndIF
        );
    }

}
