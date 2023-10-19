/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import { Market } from "./Market.sol";
import { IPool } from "../interfaces/IPool.sol";

import { ExposureHelpers } from "../libraries/ExposureHelpers.sol";
import { ExecuteADLOrder } from "../libraries/actions/ExecuteADLOrder.sol";
import {
    FilledBalances,
    UnfilledBalances,
    PositionBalances,
    UnfilledExposureComponents,
    UnfilledExposure,
    PnLComponents
} from "../libraries/DataTypes.sol";
import { TraderPosition } from "../libraries/TraderPosition.sol";

import { SetUtil } from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import { Time } from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import { SafeCastU256 } from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { UD60x18 } from "@prb/math/UD60x18.sol";

/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library Portfolio {
    using Portfolio for Portfolio.Data;
    using SetUtil for SetUtil.UintSet;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastU256 for uint256;
    using Market for Market.Data;

    /**
     * @dev Thrown when a portfolio cannot be found.
     */
    error PortfolioNotFound(uint128 accountId, uint128 marketId);

    /**
     * @dev Thrown when an account exceeds the positions limit.
     */
    error TooManyTakerPositions(uint128 accountId, uint128 marketId);

    /**
     * @notice Emitted when attempting to settle before maturity
     */
    error SettlementBeforeMaturity(uint128 marketId, uint32 maturityTimestamp, uint256 accountId);

    error UnknownMarket(uint128 marketId);

    /**
     * @notice Emitted when a portfolio is created
     * @param accountId The account id of the new portfolio
     * @param marketId The market id of the new portfolio
     * @param blockTimestamp The current block timestamp
     */
    event PortfolioCreated(uint128 indexed accountId, uint128 indexed marketId, uint256 blockTimestamp);

    /**
     * @notice Emitted when a position in updated.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param balances The newly updated position balances.
     * @param blockTimestamp The current block timestamp.
     */
    event PositionUpdated(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        PositionBalances balances,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when a new market maturity is activated
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The new active maturity timestamp
     * @param blockTimestamp The current block timestamp.
     */
    event MarketMaturityActivated(
        uint128 indexed accountId, uint128 indexed marketId, uint32 maturityTimestamp, uint256 blockTimestamp
    );

    /**
     * @notice Emitted when an existing market maturity is deactivated
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The deactivated maturity timestamp
     * @param blockTimestamp The current block timestamp.
     */
    event MarketMaturityDeactivated(
        uint128 indexed accountId, uint128 indexed marketId, uint32 maturityTimestamp, uint256 blockTimestamp
    );

    struct Data {
        /**
         * @dev Numeric identifier for the account that owns the portfolio.
         * @dev Since a given account can only own a single portfolio in a given dated market
         * the id of the portfolio is the same as the id of the account
         * @dev There cannot be an account and hence dated portfolio with id zero
         */
        uint128 accountId;
        uint128 marketId;
        /**
         * @dev maturityTimestamp (e.g. 31st Dec 2023) --> Position object with filled balances
         */
        mapping(uint32 maturityTimestamp => PositionBalances) positions;
        /**
         * @dev Mapping from settlementToken to an
         * array of marketId (e.g. aUSDC lend) and activeMaturities (e.g. 31st Dec 2023)
         * in which the account has active positions
         */
        SetUtil.UintSet activeMaturities;
    }

    /**
     * @dev Returns the portfolio stored at the specified portfolio id
     * @dev Same as account id of the account that owns the portfolio of dated irs positions
     */
    function load(uint128 accountId, uint128 marketId) private pure returns (Data storage portfolio) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Portfolio", accountId, marketId));
        assembly {
            portfolio.slot := s
        }
    }

    function loadOrCreate(uint128 accountId, uint128 marketId) internal returns (Data storage portfolio) {
        portfolio = load(accountId, marketId);

        if (portfolio.accountId == 0) {
            portfolio.accountId = accountId;
            portfolio.marketId = marketId;
            emit PortfolioCreated(accountId, marketId, block.timestamp);
        }
    }

    /**
     * @dev Reverts if the portfolio does not exist with appropriate error. Otherwise, returns the portfolio.
     */
    function exists(uint128 accountId, uint128 marketId) internal view returns (Data storage portfolio) {
        portfolio = load(accountId, marketId);

        if (portfolio.accountId != accountId || portfolio.marketId != marketId) {
            revert PortfolioNotFound(accountId, marketId);
        }
    }

    function getAccountPositionBalances(
        Data storage self,
        uint32 maturityTimestamp,
        address poolAddress
    )
        internal
        view
        returns (PositionBalances memory)
    {
        PositionBalances memory poolBalances =
            IPool(poolAddress).getAccountPositionBalances(self.marketId, maturityTimestamp, self.accountId);

        PositionBalances memory marketBalances = self.positions[maturityTimestamp];

        return PositionBalances({
            base: poolBalances.base + marketBalances.base,
            quote: poolBalances.quote + marketBalances.quote,
            extraCashflow: poolBalances.extraCashflow + marketBalances.extraCashflow
        });
    }

    function getAccountFilledBalances(
        Data storage self,
        uint32 maturityTimestamp,
        address poolAddress
    )
        internal
        view
        returns (FilledBalances memory)
    {
        PositionBalances memory position = self.getAccountPositionBalances(maturityTimestamp, poolAddress);

        int256 realizedPnL = TraderPosition.getAccruedInterest(
            position, Market.exists(self.marketId).getLatestRateIndex(maturityTimestamp)
        );

        UD60x18 twap = ExposureHelpers.computeTwap(self.marketId, maturityTimestamp, poolAddress, position.base);

        int256 unrealizedPnL =
            ExposureHelpers.computeUnrealizedPnL(self.marketId, maturityTimestamp, position.base, position.quote, twap);

        return FilledBalances({
            base: position.base,
            quote: position.quote,
            pnl: PnLComponents({ realizedPnL: realizedPnL, unrealizedPnL: unrealizedPnL })
        });
    }

    function getAccountMakerExposures(Data storage self)
        internal
        view
        returns (UnfilledExposure[] memory unfilledExposures)
    {
        uint256 size = 0;

        Market.Data storage market = Market.exists(self.marketId);
        address poolAddress = market.marketConfig.poolAddress;
        UD60x18 exposureFactor = market.exposureFactor();

        uint256 riskMatrixZeroRowId = market.marketMaturityConfigs[0].riskMatrixRowId;
        uint256 activeMaturitiesLength = self.activeMaturities.length();

        UnfilledBalances[] memory cachedUnfilledBalances = new UnfilledBalances[](activeMaturitiesLength);

        for (uint256 i = 1; i <= activeMaturitiesLength; i++) {
            uint32 maturityTimestamp = self.activeMaturities.valueAt(i).to32();

            cachedUnfilledBalances[i - 1] =
                IPool(poolAddress).getAccountUnfilledBalances(market.id, maturityTimestamp, self.accountId);

            if (cachedUnfilledBalances[i - 1].baseLong == 0 && cachedUnfilledBalances[i - 1].baseShort == 0) {
                continue;
            }

            size += 1;
        }

        unfilledExposures = new UnfilledExposure[](size);
        size = 0;

        for (uint256 i = 1; i <= activeMaturitiesLength; i++) {
            uint32 maturityTimestamp = self.activeMaturities.valueAt(i).to32();
            Market.MarketMaturityConfiguration memory marketMaturityConfig =
                market.marketMaturityConfigs[maturityTimestamp];

            if (cachedUnfilledBalances[i - 1].baseLong == 0 && cachedUnfilledBalances[i - 1].baseShort == 0) {
                continue;
            }

            unfilledExposures[size].exposureComponents = UnfilledExposureComponents({
                long: ExposureHelpers.getExposureComponents(
                    cachedUnfilledBalances[i - 1].baseLong.toInt(),
                    exposureFactor,
                    marketMaturityConfig.tenorInSeconds,
                    maturityTimestamp
                    ),
                short: ExposureHelpers.getExposureComponents(
                    cachedUnfilledBalances[i - 1].baseShort.toInt(),
                    exposureFactor,
                    marketMaturityConfig.tenorInSeconds,
                    maturityTimestamp
                    )
            });

            unfilledExposures[size].riskMatrixRowIds[0] = riskMatrixZeroRowId;
            unfilledExposures[size].riskMatrixRowIds[1] = marketMaturityConfig.riskMatrixRowId;

            unfilledExposures[size].pvmrComponents = ExposureHelpers.getPVMRComponents(
                cachedUnfilledBalances[i - 1], market.id, maturityTimestamp, marketMaturityConfig.riskMatrixRowId
            );

            size += 1;
        }
    }

    function getAccountTakerExposures(
        Data storage self,
        uint256 riskMatrixDim
    )
        internal
        view
        returns (int256[] memory filledExposures)
    {
        filledExposures = new int256[](riskMatrixDim);

        Market.Data storage market = Market.exists(self.marketId);
        address poolAddress = market.marketConfig.poolAddress;
        UD60x18 exposureFactor = market.exposureFactor();

        uint256 riskMatrixZeroRowId = market.marketMaturityConfigs[0].riskMatrixRowId;

        for (uint256 i = 1; i <= self.activeMaturities.length(); i++) {
            uint32 maturityTimestamp = self.activeMaturities.valueAt(i).to32();
            Market.MarketMaturityConfiguration memory marketMaturityConfig =
                market.marketMaturityConfigs[maturityTimestamp];

            FilledBalances memory filledBalances = getAccountFilledBalances(self, maturityTimestamp, poolAddress);

            int256[] memory exposureComponents = ExposureHelpers.getExposureComponents(
                filledBalances.base, exposureFactor, marketMaturityConfig.tenorInSeconds, maturityTimestamp
            );

            filledExposures[riskMatrixZeroRowId] += exposureComponents[0];
            filledExposures[marketMaturityConfig.riskMatrixRowId] += exposureComponents[1];
        }
    }

    function propagateMatchedOrder(
        Data storage taker,
        Data storage maker,
        int256 base,
        int256 quote,
        uint32 maturityTimestamp
    )
        internal
    {
        int256 extraCashflow = TraderPosition.computeCashflow(
            base, quote, Market.exists(taker.marketId).getLatestRateIndex(maturityTimestamp)
        );

        taker.updatePosition(
            maturityTimestamp, PositionBalances({ base: base, quote: quote, extraCashflow: extraCashflow })
        );

        maker.updatePosition(
            maturityTimestamp, PositionBalances({ base: -base, quote: -quote, extraCashflow: -extraCashflow })
        );
    }

    /**
     * @dev create, edit or close an irs position for a given marketId (e.g. aUSDC lend) and maturityTimestamp (e.g. 31st
     * Dec 2023)
     */
    function updatePosition(
        Data storage self,
        uint32 maturityTimestamp,
        PositionBalances memory tokenDeltas
    )
        internal
    {
        PositionBalances storage position = self.positions[maturityTimestamp];

        // register active market
        activateMarketMaturity(self, maturityTimestamp);

        position.base += tokenDeltas.base;
        position.quote += tokenDeltas.quote;
        position.extraCashflow += tokenDeltas.extraCashflow;

        emit PositionUpdated(self.accountId, self.marketId, maturityTimestamp, position, block.timestamp);
    }

    /**
     * @dev create, edit or close an irs position for a given marketId (e.g. aUSDC lend) and maturityTimestamp (e.g. 31st
     * Dec 2023)
     */
    function settle(
        Data storage self,
        uint32 maturityTimestamp,
        address poolAddress
    )
        internal
        returns (int256 settlementCashflow)
    {
        if (maturityTimestamp > Time.blockTimestampTruncated()) {
            revert SettlementBeforeMaturity(self.marketId, maturityTimestamp, self.accountId);
        }

        settlementCashflow = self.getAccountFilledBalances(maturityTimestamp, poolAddress).pnl.realizedPnL;

        /// @dev reverts if not active
        deactivateMarketMaturity(self, maturityTimestamp);
    }

    /**
     * @dev set market and maturity as active
     * note this can also be called by the pool when a position is intitalised
     */
    function activateMarketMaturity(Data storage self, uint32 maturityTimestamp) private {
        if (self.activeMaturities.contains(maturityTimestamp)) {
            return;
        }

        if (self.activeMaturities.length() >= Market.exists(self.marketId).marketConfig.takerPositionsPerAccountLimit) {
            revert TooManyTakerPositions(self.accountId, self.marketId);
        }

        self.activeMaturities.add(maturityTimestamp);

        emit MarketMaturityActivated(self.accountId, self.marketId, maturityTimestamp, block.timestamp);
    }

    /**
     * @dev set market and maturity as inactive
     * note this can also be called by the pool when a position is settled
     */
    function deactivateMarketMaturity(Data storage self, uint32 maturityTimestamp) private {
        self.activeMaturities.remove(maturityTimestamp);
        emit MarketMaturityDeactivated(self.accountId, self.marketId, maturityTimestamp, block.timestamp);
    }

    function hasUnfilledOrders(Data storage self) internal view returns (bool) {
        Market.Data storage market = Market.exists(self.marketId);

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            if (
                IPool(market.marketConfig.poolAddress).hasUnfilledOrders(
                    self.marketId, maturityTimestamp, self.accountId
                )
            ) {
                return true;
            }
        }

        return false;
    }

    function closeAllUnfilledOrders(Data storage self) internal returns (uint256 closedUnfilledBasePool) {
        Market.Data storage market = Market.exists(self.marketId);

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            closedUnfilledBasePool += IPool(market.marketConfig.poolAddress).closeUnfilledBase(
                self.marketId, maturityTimestamp, self.accountId
            );
        }
    }

    function executeADLOrder(
        Data storage self,
        bool adlNegativeUpnl,
        bool adlPositiveUpnl,
        uint256 totalUnrealizedLossQuote,
        int256 realBalanceAndIF
    )
        internal
    {
        Market.Data storage market = Market.exists(self.marketId);
        address poolAddress = market.marketConfig.poolAddress;

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            int256 unrealizedPnL = getAccountFilledBalances(self, maturityTimestamp, poolAddress).pnl.unrealizedPnL;

            // lower and upper exposures are the same, since no unfilled orders should be present at this poin
            bool executeADL = (adlNegativeUpnl && unrealizedPnL < 0) || (adlPositiveUpnl && unrealizedPnL > 0);

            if (executeADL) {
                ExecuteADLOrder.executeADLOrder(self, maturityTimestamp, totalUnrealizedLossQuote, realBalanceAndIF);
            }
        }
    }
}
