pragma solidity >=0.8.19;

import "@voltz-protocol/util-contracts/src/helpers/SetUtil.sol";
import "@voltz-protocol/util-contracts/src/ownership/Ownable.sol";

library FeatureFlag {
    using SetUtil for SetUtil.AddressSet;

    error FeatureUnavailable(bytes32 which);

    error Unauthorized(address addr);

    struct Data {
        bytes32 name;
        address owner;
        bool allowAll;
        bool denyAll;
        SetUtil.AddressSet permissionedAddresses;
        address[] deniers;
    }

    function load(bytes32 featureName) internal pure returns (Data storage store) {
        bytes32 s = keccak256(abi.encode("xyz.voltz.FeatureFlag", featureName));
        assembly {
            store.slot := s
        }
    }

    function setOwner(Data storage feature, address owner) internal {
        feature.owner = owner;
    }

    function onlyOwner(Data storage feature) internal view {
        address featureOwner = feature.owner;

        if (featureOwner == address(0)) {
            featureOwner = OwnableStorage.getOwner();
        }

        if (msg.sender != featureOwner) {
            revert Unauthorized(msg.sender);
        }
    }

    function ensureAccessToFeature(bytes32 feature) internal view {
        if (!hasAccess(feature, msg.sender)) {
            revert FeatureUnavailable(feature);
        }
    }

    function hasAccess(bytes32 feature, address value) internal view returns (bool) {
        Data storage store = FeatureFlag.load(feature);

        if (store.denyAll) {
            return false;
        }

        return store.allowAll || store.permissionedAddresses.contains(value);
    }

    function isDenier(Data storage self, address possibleDenier) internal view returns (bool) {
        for (uint256 i = 0; i < self.deniers.length; i++) {
            if (self.deniers[i] == possibleDenier) {
                return true;
            }
        }

        return false;
    }
}
