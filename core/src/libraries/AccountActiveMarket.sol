/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";

import "../storage/Account.sol";
import "../storage/CollateralPool.sol";
import "../storage/Market.sol";

/**
 * @title Object for tracking account active markets.
 */
library AccountActiveMarket {
    using Account for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using Market for Market.Data;
    using SetUtil for SetUtil.AddressSet;
    using SetUtil for SetUtil.UintSet;

    /**
     * @notice Thrown when an attempt to propagate an order with a market with which the account cannot engage.
     */
    // todo: consider if more information needs to be included in this error beyond accountId and marketId
    error AccountCannotEngageWithMarket(uint128 accountId, uint128 marketId);

    /**
     * @notice Emitted when the account is active on a new market.
     * @param accountId The id of the account.
     * @param marketId The id of the new active market.
     * @param blockTimestamp The current block timestamp.
     */
    event ActiveMarketUpdated(uint128 indexed accountId, uint128 marketId, uint256 blockTimestamp);
    
    /**
     * @dev Marks that the account is active on particular market.
     */
    function markActiveMarket(Account.Data storage self, address collateralType, uint128 marketId) internal {
        // skip if account is already active on this market
        if (self.activeMarketsPerQuoteToken[collateralType].contains(marketId)) {
            return;
        }

        // check if account can interact with this market
        if (self.firstMarketId == 0) {
            self.firstMarketId = marketId;

            // account is linked the first time to some collateral pool - update the collateral pool balances
            CollateralPool.Data storage collateralPool = Market.exists(marketId).getCollateralPool();
            for (uint256 i = 1; i <= self.activeCollaterals.length(); i++) {
                address collateralType = self.activeCollaterals.valueAt(i);
                collateralPool.increaseCollateralBalance(collateralType, self.collateralBalances[collateralType]);
            }
        }
        else {
            // get collateral pool ID of the account
            uint128 accountCollateralPoolId = 
                Market.exists(self.firstMarketId).getCollateralPool().id;
    
            // get collateral pool ID of the new market
            uint128 marketCollateralPoolId = 
                Market.exists(marketId).getCollateralPool().id;

            // if the collateral pools are different, account cannot engage with the new market
            if (accountCollateralPoolId != marketCollateralPoolId) {
                revert AccountCannotEngageWithMarket(self.id, marketId);
            }
        }

        // add the collateral type to the account active quote tokens if missing
        if (!self.activeQuoteTokens.contains(collateralType)) {
            self.activeQuoteTokens.add(collateralType);
        }

        // add the market to the account active markets
        self.activeMarketsPerQuoteToken[collateralType].add(marketId);

        emit ActiveMarketUpdated(self.id, marketId, block.timestamp);
    }
}
