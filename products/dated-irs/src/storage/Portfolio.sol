/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {Position} from "./Position.sol";
import {Market} from "./Market.sol";
import {IPool} from "../interfaces/IPool.sol";
import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";
import {ExecuteADLOrder} from "../libraries/actions/ExecuteADLOrder.sol";

import {Account} from "@voltz-protocol/core/src/storage/Account.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {Time} from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import {DecimalMath} from "@voltz-protocol/util-contracts/src/helpers/DecimalMath.sol";
import {IERC20} from "@voltz-protocol/util-contracts/src/interfaces/IERC20.sol";

import { UD60x18 } from "@prb/math/UD60x18.sol";


/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library Portfolio {
    using Portfolio for Portfolio.Data;
    using Position for Position.Data;
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
    event PortfolioCreated(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when a position in updated.
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The maturity timestamp of the position.
     * @param baseDelta The delta in position base balance.
     * @param quoteDelta The delta in position quote balance.
     * @param blockTimestamp The current block timestamp.
     */
    event PositionUpdated(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 indexed maturityTimestamp,
        int256 baseDelta,
        int256 quoteDelta,
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
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 maturityTimestamp,
        uint256 blockTimestamp
    );

    /**
     * @notice Emitted when an existing market maturity is deactivated
     * @param accountId The id of the account.
     * @param marketId The id of the market.
     * @param maturityTimestamp The deactivated maturity timestamp
     * @param blockTimestamp The current block timestamp.
     */
    event MarketMaturityDeactivated(
        uint128 indexed accountId,
        uint128 indexed marketId,
        uint32 maturityTimestamp,
        uint256 blockTimestamp
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
        mapping(uint32 => Position.Data) positions;

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

        if (portfolio.accountId == 0)  {
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

    function getPoolExposureState(
        Data storage self,
        uint32 maturityTimestamp,
        address poolAddress
    ) internal view returns (ExposureHelpers.PoolExposureState memory poolState) {
        (int256 baseBalancePool, int256 quoteBalancePool, int256 accruedInterestPool) = IPool(poolAddress).getAccountFilledBalances(
            self.marketId, 
            maturityTimestamp, 
            self.accountId
        );

        (uint256 unfilledBaseLong, uint256 unfilledBaseShort, uint256 unfilledQuoteLong, uint256 unfilledQuoteShort) =
            IPool(poolAddress).getAccountUnfilledBaseAndQuote(
                self.marketId, 
                maturityTimestamp, 
                self.accountId
            );

        return ExposureHelpers.PoolExposureState({
            marketId: self.marketId,
            maturityTimestamp: maturityTimestamp,

            annualizedExposureFactor: 
                ExposureHelpers.annualizedExposureFactor(
                    self.marketId,
                    maturityTimestamp
                ),

            baseBalance: self.positions[poolState.maturityTimestamp].baseBalance,
            quoteBalance: self.positions[poolState.maturityTimestamp].quoteBalance,
            accruedInterest: self.positions[poolState.maturityTimestamp].accruedInterestTrackers.accruedInterest,

            baseBalancePool: baseBalancePool,
            quoteBalancePool: quoteBalancePool,
            accruedInterestPool: accruedInterestPool,

            unfilledBaseLong: unfilledBaseLong,
            unfilledQuoteLong: unfilledQuoteLong,
            unfilledBaseShort: unfilledBaseShort,
            unfilledQuoteShort: unfilledQuoteShort
        });
    }

    function getAccountExposuresPerMaturity(
        Data storage self,
        address poolAddress,
        uint32 maturityTimestamp
    ) internal view returns (Account.MakerMarketExposure memory exposure) {
        ExposureHelpers.PoolExposureState memory poolState = getPoolExposureState(
            self,
            maturityTimestamp,
            poolAddress
        );

        // unfilled exposures => consider maker lower
        exposure.lower = 
            ExposureHelpers.getUnfilledExposureLowerInPool(poolState, poolAddress);

        exposure.upper = 
            ExposureHelpers.getUnfilledExposureUpperInPool(poolState, poolAddress);
    }

    function getAccountTakerAndMakerExposures(
        Data storage self
    )
        internal
        view
        returns (Account.MakerMarketExposure[] memory exposures)
    {
        Market.Data storage market = Market.exists(self.marketId);
        address poolAddress = market.marketConfig.poolAddress;
        uint256 activeMaturitiesCount = self.activeMaturities.length();

        for (uint256 i = 1; i <= activeMaturitiesCount; i++) {
            exposures[i - 1] = self.getAccountExposuresPerMaturity(
                poolAddress,
                self.activeMaturities.valueAt(i).to32()
            );
        }

        return exposures;
    }

    /**
     * @dev create, edit or close an irs position for a given marketId (e.g. aUSDC lend) and maturityTimestamp (e.g. 31st Dec 2023)
     */
    function updatePosition(
        Data storage self,
        uint32 maturityTimestamp,
        int256 baseDelta,
        int256 quoteDelta
    )
        internal
    {
        Position.Data storage position = self.positions[maturityTimestamp];

        // register active market
        if (position.baseBalance == 0 && position.quoteBalance == 0) {
            activateMarketMaturity(self, maturityTimestamp);
        }

        position.update(baseDelta, quoteDelta, self.marketId, maturityTimestamp);
        emit PositionUpdated(self.accountId, self.marketId, maturityTimestamp, baseDelta, quoteDelta, block.timestamp);
    }

    /**
     * @dev create, edit or close an irs position for a given marketId (e.g. aUSDC lend) and maturityTimestamp (e.g. 31st Dec 2023)
     */
    function settle(
        Data storage self,
        uint128 marketId,
        uint32 maturityTimestamp,
        address poolAddress
    )
        internal
        returns (int256 settlementCashflow)
    {
        if (maturityTimestamp > Time.blockTimestampTruncated()) {
            revert SettlementBeforeMaturity(marketId, maturityTimestamp, self.accountId);
        }

        Position.Data storage position = self.positions[maturityTimestamp];

        /// @dev reverts if not active
        self.deactivateMarketMaturity(maturityTimestamp);

        (int256 marketBase, int256 marketQuote) = (position.baseBalance, position.quoteBalance);

        /// @dev update position's accrued interest
        position.update(
            -marketBase,
            -marketQuote,
            marketId,
            maturityTimestamp
        );
        /// @dev Note that the settle function will not update the
        /// last MTM timestamp in the VAMM. However, this is not an
        /// issue since the market has been deactivated and the position
        /// cannot be settled anymore.
        (,, int256 accruedInterest) = 
            IPool(poolAddress).getAccountFilledBalances(marketId, maturityTimestamp, self.accountId);
        settlementCashflow = accruedInterest + position.accruedInterestTrackers.accruedInterest;

        emit PositionUpdated(
            self.accountId, 
            marketId, 
            maturityTimestamp, 
            -marketBase, 
            -marketQuote, 
            block.timestamp
        );
    }

    /**
     * @dev set market and maturity as active
     * note this can also be called by the pool when a position is intitalised
     */
    function activateMarketMaturity(Data storage self, uint32 maturityTimestamp) private {
        // check if market/maturity exists
        Market.Data storage market = Market.exists(self.marketId);

        address collateralType = market.quoteToken;

        if (collateralType == address(0)) {
            revert UnknownMarket(self.marketId);
        }

        if (self.activeMaturities.contains(maturityTimestamp)) {
            return;
        }
        
        if (
            self.activeMaturities.length() >= 
            market.marketConfig.takerPositionsPerAccountLimit
        ) {
            revert TooManyTakerPositions(self.accountId, self.marketId);
        }

        self.activeMaturities.add(maturityTimestamp);
        
        emit MarketMaturityActivated(
            self.accountId,
            self.marketId,
            maturityTimestamp,
            block.timestamp
        );
    }

    /**
     * @dev set market and maturity as inactive
     * note this can also be called by the pool when a position is settled
     */
    function deactivateMarketMaturity(Data storage self, uint32 maturityTimestamp) internal {
        self.activeMaturities.remove(maturityTimestamp);
        emit MarketMaturityDeactivated(
            self.accountId,
            self.marketId,
            maturityTimestamp,
            block.timestamp
        );
    }

    function hasUnfilledOrders(Data storage self) internal view returns (bool) {
        Market.Data storage market = Market.exists(self.marketId);

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            if (
                IPool(market.marketConfig.poolAddress).hasUnfilledOrders(
                    self.marketId,
                    maturityTimestamp,
                    self.accountId
                )
            ) {
                return true;
            }
        }

        return false;
    }

    function closeAllUnfilledOrders(Data storage self) internal returns (int256 closedUnfilledBasePool) {
        Market.Data storage market = Market.exists(self.marketId);

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            closedUnfilledBasePool += IPool(market.marketConfig.poolAddress).closeUnfilledBase(
                self.marketId,
                maturityTimestamp,
                self.accountId
            );
        }
    }

    function executeADLOrder(Data storage self, uint256 totalUnrealizedLossQuote, int256 realBalanceAndIF) internal {

        uint256[] memory activeMaturities = self.activeMaturities.values();

        for (uint256 i = 0; i < activeMaturities.length; i++) {
            uint32 maturityTimestamp = activeMaturities[i].to32();

            ExecuteADLOrder.executeADLOrder(
                self,
                maturityTimestamp,
                totalUnrealizedLossQuote,
                realBalanceAndIF
            );

        }

    }
}
