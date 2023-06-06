// https://github.com/Voltz-Protocol/v2-core/blob/main/products/dated-irs/LICENSE
pragma solidity >=0.8.19;

/**
 * @title Object for tracking a dated irs position
 * todo: annualization logic might fit nicely in here + any other irs position specific helpers
 */
library Position {
    struct Data {
        int256 baseBalance;
        int256 quoteBalance;
    }

    function update(Data storage self, int256 baseDelta, int256 quoteDelta) internal {
        self.baseBalance += baseDelta;
        self.quoteBalance += quoteDelta;
    }
}
