/*
Licensed under the Voltz v2 License (the "License"); you
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;
import { UD60x18 } from "@voltz-protocol/util-contracts/src/helpers/PrbMathHelper.sol";


/**
 * @title Library for priority queue of liquidation bids
 */
// reference: https://github.com/MihanixA/SummingPriorityQueue/blob/master/contracts/SummingPriorityQueue.sol
library LiquidationBidPriorityQueue {

    struct LiquidationBid {
        uint128 liquidatorAccountId;
        UD60x18 liquidatorRewardParameter;
        address quoteToken;
        uint128[] marketIds;
        bytes[] inputs;
    }

    struct Heap {
        uint256[] ranks;
        mapping(uint256 => LiquidationBid) liquidationBidsMap;
    }

    modifier notEmpty(Heap storage self) {
        require(self.ranks.length > 1);
        _;
    }

    function top(Heap storage self) internal view notEmpty(self) returns(uint256) {
        return self.ranks[1];
    }

    function topBid(Heap storage self) internal view notEmpty(self) returns(LiquidationBid memory) {
        return self.liquidationBidsMap[top(self)];
    }

    function dequeue(Heap storage self) internal notEmpty(self) {
        require(self.ranks.length > 1);

        uint256 toReturn = top(self);
        self.ranks[1] = self.ranks[self.ranks.length - 1];
        self.ranks.pop();

        uint256 i = 1;

        while (i * 2 < self.ranks.length) {
            uint256 j = i * 2;

            if (j + 1 < self.ranks.length) {
                if (self.ranks[j] > self.ranks[j + 1]) {
                    j++;
                }
            }

            if (self.ranks[i] < self.ranks[j]) {
                break;
            }

            (self.ranks[i], self.ranks[j]) = (self.ranks[j], self.ranks[i]);
            i = j;
        }
        delete self.liquidationBidsMap[toReturn];
    }


    function enqueue(Heap storage self, uint256 rank, LiquidationBid memory liquidationBid) internal {
        if (self.ranks.length == 0) {
            // todo: why initialize with a zero?
            self.ranks.push(0); // initialize
        }

        self.ranks.push(rank);
        uint256 i = self.ranks.length - 1;

        while (i > 1 && self.ranks[i / 2] > self.ranks[i]) {
            (self.ranks[i / 2], self.ranks[i]) = (rank, self.ranks[i / 2]);
            i /= 2;
        }

        self.liquidationBidsMap[rank] = liquidationBid;
    }

    // todo: consider removing this function (feels redundunt)
    function drain(Heap storage self, uint256 rankThreshold) internal {
        while (self.ranks.length > 1 && top(self) < rankThreshold) {
            dequeue(self);
        }

    }

}