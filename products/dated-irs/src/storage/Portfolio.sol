/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/helpers/SafeCast.sol";
import "@voltz-protocol/util-contracts/src/helpers/Time.sol";
import "@voltz-protocol/util-contracts/src/helpers/Pack.sol";
import "@voltz-protocol/core/src/interfaces/IMarketManagerModule.sol";
import "./Position.sol";
import "./RateOracleReader.sol";
import "./MarketConfiguration.sol";
import "./MarketManagerConfiguration.sol";
import "../interfaces/IPool.sol";
import "../libraries/ExposureHelpers.sol";
import "@voltz-protocol/core/src/storage/Account.sol";
import "@voltz-protocol/core/src/interfaces/IRiskConfigurationModule.sol";
import { UD60x18, UNIT, unwrap } from "@prb/math/UD60x18.sol";
import { SD59x18 } from "@prb/math/SD59x18.sol";
import { mulUDxUint, mulUDxInt } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";

/**
 * @title Object for tracking a portfolio of dated interest rate swap positions
 */
library Portfolio {
    using Portfolio for Portfolio.Data;
    using Position for Position.Data;
    using SetUtil for SetUtil.UintSet;
    using SetUtil for SetUtil.AddressSet;
    using SafeCastU256 for uint256;
    using RateOracleReader for RateOracleReader.Data;

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
    function load(uint128 accountId, uint128 marketId) internal pure returns (Data storage portfolio) {
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

    struct CollateralExposureState {
        uint256 poolsCount;
        uint256 takerExposuresLength;
        uint256 makerExposuresLowerAndUpperLength;
    }

    struct PoolExposureState {
        uint128 marketId;
        uint32 maturityTimestamp;
        int256 baseBalance;
        int256 baseBalancePool;
        int256 quoteBalance;
        int256 quoteBalancePool;
        uint256 unfilledBaseLong;
        uint256 unfilledQuoteLong;
        uint256 unfilledBaseShort;
        uint256 unfilledQuoteShort;
        UD60x18 _annualizedExposureFactor;
    }

    struct Exposures {
        Account.Exposure[] taker;
        uint256 takerIndex;
        Account.Exposure[] makerLower;
        Account.Exposure[] makerUpper;
        uint256 makerIndex;
    }

    function getAccountTakerAndMakerExposuresWithEmptySlots(
        Data storage self,
        address poolAddress,
        Exposures memory initExposures
    ) internal view returns (Account.Exposure[] memory, Account.Exposure[] memory, Account.Exposure[] memory, uint256, uint256) {

        CollateralExposureState memory collateralState = CollateralExposureState({
            poolsCount: self.activeMaturities.length(),
            takerExposuresLength: initExposures.takerIndex,
            makerExposuresLowerAndUpperLength: initExposures.makerIndex
        });


        for (uint256 i = 1; i <= collateralState.poolsCount; i++) {
            PoolExposureState memory poolState = self.getPoolExposureState(
                i,
                poolAddress
            );

            if (poolState.unfilledBaseLong == 0 && poolState.unfilledBaseShort == 0) {
                // no unfilled exposures => only consider taker exposures
                initExposures.taker[collateralState.takerExposuresLength] = 
                    ExposureHelpers.getOnlyFilledExposureInPool(poolState, poolAddress);
            
                collateralState.takerExposuresLength = collateralState.takerExposuresLength + 1;
            } else {
                // unfilled exposures => consider maker lower
                initExposures.makerLower[collateralState.makerExposuresLowerAndUpperLength] = 
                    ExposureHelpers.getUnfilledExposureLowerInPool(poolState, poolAddress);
                
                initExposures.makerUpper[collateralState.makerExposuresLowerAndUpperLength] = 
                    ExposureHelpers.getUnfilledExposureUpperInPool(poolState, poolAddress);

                collateralState.makerExposuresLowerAndUpperLength = collateralState.makerExposuresLowerAndUpperLength + 1;
            }
        }

        return (
            initExposures.taker,
            initExposures.makerLower,
            initExposures.makerUpper,
            collateralState.takerExposuresLength,
            collateralState.makerExposuresLowerAndUpperLength
        );
    }

    function getPoolExposureState(
        Data storage self,
        uint256 index,
        address poolAddress
    ) internal view returns (PoolExposureState memory poolState) {
        poolState.marketId = self.marketId;

        poolState.maturityTimestamp = self.activeMaturities.valueAt(index).to32();

        poolState.baseBalance = self.positions[poolState.maturityTimestamp].baseBalance;
        poolState.quoteBalance = self.positions[poolState.maturityTimestamp].quoteBalance;

        (poolState.baseBalancePool,poolState.quoteBalancePool) = IPool(poolAddress).getAccountFilledBalances(
            poolState.marketId, poolState.maturityTimestamp, self.accountId);

        (poolState.unfilledBaseLong, poolState.unfilledBaseShort, poolState.unfilledQuoteLong, poolState.unfilledQuoteShort) =
            IPool(poolAddress).getAccountUnfilledBaseAndQuote(poolState.marketId, poolState.maturityTimestamp, self.accountId);
        
        poolState._annualizedExposureFactor = ExposureHelpers.annualizedExposureFactor(
            poolState.marketId,
            poolState.maturityTimestamp
        );
    }

    function getAccountTakerAndMakerExposures(
        Data storage self
    )
        internal
        view
        returns (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        )
    {
        address poolAddress = MarketManagerConfiguration.getPoolAddress();
        uint256 marketsAndMaturitiesCount = self.activeMaturities.length();

        (
            Account.Exposure[] memory takerExposuresPadded,
            Account.Exposure[] memory makerExposuresLowerPadded,
            Account.Exposure[] memory makerExposuresUpperPadded,
            uint256 takerExposuresLength,
            uint256 makerExposuresLowerAndUpperLength
        ) = getAccountTakerAndMakerExposuresWithEmptySlots(
            self,
            poolAddress,
            Exposures({
                taker: new Account.Exposure[](marketsAndMaturitiesCount),
                takerIndex: 0,
                makerLower: new Account.Exposure[](marketsAndMaturitiesCount),
                makerUpper: new Account.Exposure[](marketsAndMaturitiesCount),
                makerIndex: 0
            })
        );

        takerExposures = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            takerExposuresPadded,
            takerExposuresLength
        );

        makerExposuresLower = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            makerExposuresLowerPadded,
            makerExposuresLowerAndUpperLength
        );

        makerExposuresUpper = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            makerExposuresUpperPadded,
            makerExposuresLowerAndUpperLength
        );

        return (takerExposures, makerExposuresLower, makerExposuresUpper);
    }

    function getAccountTakerAndMakerExposuresAllCollaterals(
        Data storage self,
        address poolAddress
    )
        internal
        view
        returns (
            Account.Exposure[] memory takerExposures,
            Account.Exposure[] memory makerExposuresLower,
            Account.Exposure[] memory makerExposuresUpper
        )
    {

        uint256 exposuresCount = self.activeMaturities.length();

        Account.Exposure[] memory takerExposuresPadded = new Account.Exposure[](exposuresCount);
        Account.Exposure[] memory makerExposuresLowerPadded = new Account.Exposure[](exposuresCount);
        Account.Exposure[] memory makerExposuresUpperPadded = new Account.Exposure[](exposuresCount);

        uint256 takerExposuresLength = 0;
        uint256 makerExposuresLowerAndUpperLength = 0;

        (
            takerExposuresPadded,
            makerExposuresLowerPadded,
            makerExposuresUpperPadded,
            takerExposuresLength,
            makerExposuresLowerAndUpperLength
        ) = getAccountTakerAndMakerExposuresWithEmptySlots(
            self,
            poolAddress,
            Exposures({
                taker: takerExposuresPadded,
                takerIndex: takerExposuresLength,
                makerLower: makerExposuresLowerPadded,
                makerUpper: makerExposuresUpperPadded,
                makerIndex: makerExposuresLowerAndUpperLength
            })
        );

        takerExposures = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            takerExposuresPadded,
            takerExposuresLength
        );

        makerExposuresLower = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            makerExposuresLowerPadded,
            makerExposuresLowerAndUpperLength
        );

        makerExposuresUpper = ExposureHelpers.removeEmptySlotsFromExposuresArray(
            makerExposuresUpperPadded,
            makerExposuresLowerAndUpperLength
        );

        return (takerExposures, makerExposuresLower, makerExposuresUpper);
    }

    /**
     * @dev Fully Close all the positions owned by the account within the dated irs portfolio
     * poolAddress in which to close the account, note in the beginning we'll only have a single pool
     */
    function closeAccount(Data storage self) internal {
        IPool pool = IPool(MarketManagerConfiguration.getPoolAddress());

        address collateralType = MarketConfiguration.load(self.marketId).quoteToken;

        for (uint256 i = 1; i <= self.activeMaturities.length(); i++) {
            uint32 maturityTimestamp = self.activeMaturities.valueAt(i).to32();

            Position.Data storage position = self.positions[maturityTimestamp];

            pool.closeUnfilledBase(self.marketId, maturityTimestamp, self.accountId);

            // left-over exposure in pool
            (int256 filledBasePool,) = pool.getAccountFilledBalances(self.marketId, maturityTimestamp, self.accountId);

            int256 unwindBase = -(position.baseBalance + filledBasePool);

            (int256 executedBaseAmount, int256 executedQuoteAmount) =
                pool.executeDatedTakerOrder(self.marketId, maturityTimestamp, unwindBase, 0);

            position.update(executedBaseAmount, executedQuoteAmount);

            UD60x18 _annualizedExposureFactor = ExposureHelpers.annualizedExposureFactor(self.marketId, maturityTimestamp);

            IMarketManagerModule(MarketManagerConfiguration.getCoreProxyAddress()).propagateTakerOrder(
                self.accountId,
                self.marketId,
                collateralType,
                mulUDxInt(_annualizedExposureFactor, executedBaseAmount)
            );

            RateOracleReader.load(self.marketId).updateOracleStateIfNeeded();

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

        UD60x18 liquidityIndexMaturity = RateOracleReader.load(marketId).getRateIndexMaturity(maturityTimestamp);

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
        address collateralType = MarketConfiguration.load(self.marketId).quoteToken;

        if (collateralType == address(0)) {
            revert UnknownMarket(self.marketId);
        }

        if (!self.activeMaturities.contains(maturityTimestamp)) {
            if (
                self.activeMaturities.length() >= 
                MarketManagerConfiguration.load().takerPositionsPerAccountLimit
            ) {
                revert TooManyTakerPositions(self.accountId, self.marketId);
            }

            self.activeMaturities.add(maturityTimestamp);
        }
    }

    /**
     * @dev set market and maturity as inactive
     * note this can also be called by the pool when a position is settled
     */
    function deactivateMarketMaturity(Data storage self, uint32 maturityTimestamp) internal {
        if (self.activeMaturities.contains(maturityTimestamp)) {
            self.activeMaturities.remove(maturityTimestamp);
        }
    }
}
