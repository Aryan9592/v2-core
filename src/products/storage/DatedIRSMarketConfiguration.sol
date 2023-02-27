//SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/**
 * @title Tracks configurations for dated irs markets
 */
library DatedIRSMarketConfiguration {
    struct Data {
        // todo: new market ids should be created here
        /**
         * @dev Id fo a given interest rate swap market
         */
        uint128 marketId;
        /**
         * @dev Address of the quote token.
         * @dev IRS contracts settle in the quote token
         * i.e. settlement cashflows and unrealized pnls are in quote token terms
         */
        address quoteToken;
    }

    /**
     * @dev Loads the DatedIRSMarketConfiguration object for the given dated irs market id
     * @param irsMarketId Id of the IRS market that we want to load the configurations for
     * @return datedIRSMarketConfig The CollateralConfiguration object.
     */
    function load(uint128 irsMarketId) internal pure returns (Data storage datedIRSMarketConfig) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.DatedIRSMarketConfiguration", irsMarketId));
        assembly {
            datedIRSMarketConfig.slot := s
        }
    }

    /**
     * @dev Configures a dated interest rate swap market
     * @param config The DatedIRSMarketConfiguration object with all the settings for the irs market being configured.
     */
    function set(Data memory config) internal {
        Data storage storedConfig = load(config.marketId);

        storedConfig.marketId = config.marketId;
        storedConfig.quoteToken = config.quoteToken;
    }
}
