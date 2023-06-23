// SPDX-License-Identifier: MIT
pragma solidity >=0.8.19;

import "@voltz-protocol/core/src/interfaces/ICollateralModule.sol";
import "@voltz-protocol/core/src/interfaces/IAccountModule.sol";
import "@voltz-protocol/core/src/interfaces/ICollateralConfigurationModule.sol";
import "@voltz-protocol/util-contracts/src/interfaces/IERC721.sol";
import "../storage/Config.sol";
import "./Payments.sol";

/**
 * @title Perform withdrawals and deposits to and from the v2 collateral module
 */
library V2Core {
    function deposit(uint128 accountId, address collateralType, uint256 tokenAmount) internal {
        address coreProxyAddress = Config.load().VOLTZ_V2_CORE_PROXY;
        uint256 liquidationBooster = ICollateralConfigurationModule(
            coreProxyAddress
        ).getCollateralConfiguration(collateralType).liquidationBooster;
        Payments.approveERC20Core(collateralType, tokenAmount + liquidationBooster);
        ICollateralModule(coreProxyAddress).deposit(accountId, collateralType, tokenAmount);
    }

    function withdraw(uint128 accountId, address collateralType, uint256 tokenAmount) internal {
        ICollateralModule(Config.load().VOLTZ_V2_CORE_PROXY).withdraw(accountId, collateralType, tokenAmount);
        Payments.pay(collateralType, msg.sender, tokenAmount);
    }

    function createAccount(uint128 requestedId, uint256 accessPassTokenId) internal {
        Config.Data memory config = Config.load();
        IAccountModule(config.VOLTZ_V2_CORE_PROXY).createAccount(requestedId, accessPassTokenId);
        IERC721(config.VOLTZ_V2_ACCOUNT_NFT_PROXY).safeTransferFrom(address(this), msg.sender, requestedId);
    }
}
