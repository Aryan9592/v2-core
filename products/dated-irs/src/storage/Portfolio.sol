/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import {Position} from "./Position.sol";
import {Market} from "./Market.sol";
import {MarketManagerConfiguration} from "./MarketManagerConfiguration.sol";
import {IPool} from "../interfaces/IPool.sol";
import {ExposureHelpers} from "../libraries/ExposureHelpers.sol";

import {IMarketManagerModule} from "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";
import {Account} from "@voltz-protocol/core/src/storage/Account.sol";

import {SetUtil} from "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import {Time} from "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import {SafeCastU256} from "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import { mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

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
        poolState.marketId = self.marketId;
        poolState.maturityTimestamp = maturityTimestamp;

        poolState.baseBalance = self.positions[poolState.maturityTimestamp].baseBalance;
        poolState.quoteBalance = self.positions[poolState.maturityTimestamp].quoteBalance;

        (poolState.baseBalancePool, poolState.quoteBalancePool) = IPool(poolAddress).getAccountFilledBalances(
            poolState.marketId, 
            poolState.maturityTimestamp, 
            self.accountId
        );

        (poolState.unfilledBaseLong, poolState.unfilledBaseShort, poolState.unfilledQuoteLong, poolState.unfilledQuoteShort) =
            IPool(poolAddress).getAccountUnfilledBaseAndQuote(
                poolState.marketId, 
                poolState.maturityTimestamp, 
                self.accountId
            );
        
        poolState.annualizedExposureFactor = ExposureHelpers.annualizedExposureFactor(
            poolState.marketId,
            poolState.maturityTimestamp
        );
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
            ExposureHelpers.PoolExposureState memory poolState = self.getPoolExposureState(
                self.activeMaturities.valueAt(i).to32(),
                poolAddress
            );

            // unfilled exposures => consider maker lower
            exposures[i - 1].lower = 
                ExposureHelpers.getUnfilledExposureLowerInPool(poolState, poolAddress);
    
            exposures[i - 1].upper = 
                ExposureHelpers.getUnfilledExposureUpperInPool(poolState, poolAddress);
        }

        return exposures;
    }

    /**
     * @dev Fully Close all the positions owned by the account within the dated irs portfolio
     * poolAddress in which to close the account, note in the beginning we'll only have a single pool
     */
    function closeAccount(Data storage self) internal {
        Market.Data storage market = Market.exists(self.marketId);

        for (uint256 i = 1; i <= self.activeMaturities.length(); i++) {
            uint32 maturityTimestamp = self.activeMaturities.valueAt(i).to32();

            Position.Data storage position = self.positions[maturityTimestamp];

            IPool(
                market.marketConfig.poolAddress
            ).closeUnfilledBase(self.marketId, maturityTimestamp, self.accountId);

            // left-over exposure in pool
            (int256 filledBasePool,) = IPool(
                market.marketConfig.poolAddress
            ).getAccountFilledBalances(self.marketId, maturityTimestamp, self.accountId);

            int256 unwindBase = -(position.baseBalance + filledBasePool);

            // todo: check with @ab if we want it adjusted or not
            UD60x18 markPrice = IPool(market.marketConfig.poolAddress).getAdjustedDatedIRSTwap(
                self.marketId, 
                maturityTimestamp, 
                unwindBase, 
                market.marketConfig.twapLookbackWindow
            );

            (int256 executedBaseAmount, int256 executedQuoteAmount) =
                IPool(market.marketConfig.poolAddress).executeDatedTakerOrder(
                    self.marketId, 
                    maturityTimestamp, 
                    unwindBase, 
                    0, 
                    markPrice, 
                    market.marketConfig.markPriceBand
                );

            position.update(executedBaseAmount, executedQuoteAmount);

            UD60x18 annualizedExposureFactor = ExposureHelpers.annualizedExposureFactor(self.marketId, maturityTimestamp);

            // todo: propagation!

            market.updateOracleStateIfNeeded();

            emit PositionUpdated(
                self.accountId, 
                self.marketId, 
                maturityTimestamp, 
                executedBaseAmount, 
                executedQuoteAmount, 
                block.timestamp
            );
        }
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
            self.activateMarketMaturity(maturityTimestamp);
        }

        position.update(baseDelta, quoteDelta);
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

        UD60x18 liquidityIndexMaturity = Market.exists(marketId).getRateIndexMaturity(maturityTimestamp);

        self.deactivateMarketMaturity(maturityTimestamp);

        IPool pool = IPool(poolAddress);

        (int256 filledBase, int256 filledQuote) = pool.getAccountFilledBalances(marketId, maturityTimestamp, self.accountId);

        settlementCashflow =
            mulUDxInt(liquidityIndexMaturity, position.baseBalance + filledBase) + position.quoteBalance + filledQuote;

        emit PositionUpdated(
            self.accountId, 
            marketId, 
            maturityTimestamp, 
            -position.baseBalance, 
            -position.quoteBalance, 
            block.timestamp
        );

        position.update(-position.baseBalance, -position.quoteBalance);
    }

    /**
     * @dev set market and maturity as active
     * note this can also be called by the pool when a position is intitalised
     */
    function activateMarketMaturity(Data storage self, uint32 maturityTimestamp) internal {
        // check if market/maturity exist
        Market.Data storage market = Market.exists(self.marketId);

        address collateralType = market.quoteToken;

        if (collateralType == address(0)) {
            revert UnknownMarket(self.marketId);
        }

        if (!self.activeMaturities.contains(maturityTimestamp)) {
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
    }

    /**
     * @dev set market and maturity as inactive
     * note this can also be called by the pool when a position is settled
     */
    function deactivateMarketMaturity(Data storage self, uint32 maturityTimestamp) internal {
        if (self.activeMaturities.contains(maturityTimestamp)) {
            self.activeMaturities.remove(maturityTimestamp);
            emit MarketMaturityDeactivated(
                self.accountId,
                self.marketId,
                maturityTimestamp,
                block.timestamp
            );
        }
    }
}
