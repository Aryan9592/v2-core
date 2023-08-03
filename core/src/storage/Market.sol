/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/errors/AccessError.sol";
import "../interfaces/external/IMarketManager.sol";
import "./Account.sol";

/**
 * @title Connects external contracts that implement the `IMarketManager` interface to the protocol.
 *
 */
library Market {
    struct Data {
        /**
         * @dev Numeric identifier for the market. Must be unique.
         * @dev There cannot be a market with id zero (See MarketCreator.create()). Id zero is used as a null market reference.
         */
        uint128 id;
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
         * @dev Creator of the market, which has configuration access rights for the market.
         */
        address owner;
    }

    /**
     * @dev Returns the market stored at the specified market id.
     */
    function load(uint128 id) internal pure returns (Data storage market) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.Market", id));
        assembly {
            market.slot := s
        }
    }

    /**
     * @dev Reverts if the caller is not the market address of the specified market
     */
    function onlyMarketAddress(uint128 marketId, address caller) internal view {
        if (Market.load(marketId).marketManagerAddress != caller) {
            revert AccessError.Unauthorized(caller);
        }
    }

    /**
     * @dev Returns taker exposures alongside maker exposures for the lower and upper bounds of the maker's range
     * for a given collateralType
     */
    function getAccountTakerAndMakerExposures(Data storage self, uint128 accountId)
        internal
        view
        returns (Account.MakerMarketExposure[] memory exposure)
    {
        return IMarketManager(self.marketManagerAddress).getAccountTakerAndMakerExposures(self.id, accountId);
    }


    /**
     * @dev The market at self.marketAddress is expected to close filled and unfilled positions for all maturities and pools
     */
    function closeAccount(Data storage self, uint128 accountId) internal {
        IMarketManager(self.marketManagerAddress).closeAccount(self.id, accountId);
    }
}
