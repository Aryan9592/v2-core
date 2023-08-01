/*
Licensed under the Voltz v2 License (the "License"); you 
may not use this file except in compliance with the License.
You may obtain a copy of the License at

https://github.com/Voltz-Protocol/v2-core/blob/main/core/LICENSE
*/
pragma solidity >=0.8.19;

import "../interfaces/ICollateralModule.sol";
import "../storage/Account.sol";
import "../storage/CollateralPool.sol";
import "../storage/CollateralConfiguration.sol";
import "@voltz-protocol/util-contracts/src/token/ERC20Helper.sol";
import "../storage/Collateral.sol";
import "@voltz-protocol/util-modules/src/storage/FeatureFlag.sol";

/**
 * @title Module for managing user collateral.
 * @dev See ICollateralModule.
 */
contract CollateralModule is ICollateralModule {
    using ERC20Helper for address;
    using CollateralConfiguration for CollateralConfiguration.Data;
    using Account for Account.Data;
    using CollateralPool for CollateralPool.Data;
    using AccountRBAC for AccountRBAC.Data;
    using Collateral for Collateral.Data;
    using SafeCastI256 for int256;
    using SafeCastU256 for uint256;

    bytes32 private constant _GLOBAL_FEATURE_FLAG = "global";

    /**
     * @inheritdoc ICollateralModule
     */
    function deposit(uint128 accountId, address collateralType, uint256 tokenAmount) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);

        // check if collateral is enabled
        CollateralConfiguration.collateralEnabled(collateralType);

        // grab the account and check its existance
        Account.Data storage account = Account.exists(accountId);

        address depositFrom = msg.sender;
        address self = address(this);

        // if liquidation booster is not full, add the delta to the deposited collateral amount
        uint256 liquidationBooster = CollateralConfiguration.load(collateralType).liquidationBooster;
        uint256 liquidationBoosterBalance = account.collaterals[collateralType].liquidationBoosterBalance;

        uint256 liquidationBoosterTopUp =
            (liquidationBooster > liquidationBoosterBalance) ? liquidationBooster - liquidationBoosterBalance : 0;

        uint256 actualTokenAmount = tokenAmount + liquidationBoosterTopUp;

        // check that this deposit does not reach the cap
        uint256 currentBalance = IERC20(collateralType).balanceOf(self);
        uint256 collateralCap = CollateralConfiguration.load(collateralType).cap;
        if (collateralCap < currentBalance + actualTokenAmount) {
            revert CollateralCapExceeded(
                collateralType, collateralCap, currentBalance, tokenAmount, liquidationBoosterTopUp
            );
        }

        // check allowance
        uint256 allowance = IERC20(collateralType).allowance(depositFrom, self);
        if (allowance < actualTokenAmount) {
            revert IERC20.InsufficientAllowance(actualTokenAmount, allowance);
        }

        // execute transfer
        collateralType.safeTransferFrom(depositFrom, self, actualTokenAmount);

        // increase the corresponding collateral pool
        CollateralPool.exists(account.trustlessProductIdTrustedByAccount)
            .increaseCollateralBalance(collateralType, actualTokenAmount);

        // update account liquidator booster balance if necessary 
        if (liquidationBoosterTopUp > 0) {
            account.collaterals[collateralType].increaseLiquidationBoosterBalance(liquidationBoosterTopUp);
            emit Collateral.LiquidatorBoosterUpdate(
                accountId, collateralType, liquidationBoosterTopUp.toInt(), block.timestamp
            );
        }

        // update account collateral balance if necessary 
        if (tokenAmount > 0) {
            account.collaterals[collateralType].increaseCollateralBalance(tokenAmount);
            emit Collateral.CollateralUpdate(accountId, collateralType, tokenAmount.toInt(), block.timestamp);
        }

        emit Deposited(accountId, collateralType, actualTokenAmount, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function withdraw(uint128 accountId, address collateralType, uint256 tokenAmount) external override {
        FeatureFlag.ensureAccessToFeature(_GLOBAL_FEATURE_FLAG);
        Account.Data storage account =
            Account.loadAccountAndValidatePermission(accountId, AccountRBAC._ADMIN_PERMISSION, msg.sender);
        CollateralPool.Data storage collateralPool = CollateralPool.exists(account.trustlessProductIdTrustedByAccount);

        uint256 collateralBalance = account.collaterals[collateralType].balance;
        if (tokenAmount > collateralBalance) {
            uint256 liquidatorBoosterWithdrawal = tokenAmount - collateralBalance;
            account.collaterals[collateralType].decreaseLiquidationBoosterBalance(liquidatorBoosterWithdrawal);
            emit Collateral.LiquidatorBoosterUpdate(
                accountId, collateralType, -liquidatorBoosterWithdrawal.toInt(), block.timestamp
            );

            account.collaterals[collateralType].decreaseCollateralBalance(collateralBalance);
            collateralPool.decreaseCollateralBalance(collateralType, collateralBalance + liquidatorBoosterWithdrawal);
            emit Collateral.CollateralUpdate(accountId, collateralType, -collateralBalance.toInt(), block.timestamp);
        } else {
            account.collaterals[collateralType].decreaseCollateralBalance(tokenAmount);
            collateralPool.decreaseCollateralBalance(collateralType, tokenAmount);
            emit Collateral.CollateralUpdate(accountId, collateralType, -tokenAmount.toInt(), block.timestamp);
        }

        if (account.isMultiToken) {
            account.imCheckAllCollaterals();
        } else {
            account.imCheck(collateralType);
        }

        collateralType.safeTransfer(msg.sender, tokenAmount);

        emit Withdrawn(accountId, collateralType, tokenAmount, msg.sender, block.timestamp);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountCollateralBalance(uint128 accountId, address collateralType)
        external
        view
        override
        returns (uint256 collateralBalance)
    {
        return Account.load(accountId).getCollateralBalance(collateralType);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountCollateralBalanceAvailable(uint128 accountId, address collateralType)
        external
        override
        view
        returns (uint256 collateralBalanceAvailable)
    {
        return Account.load(accountId).getCollateralBalanceAvailable(collateralType);
    }

    /**
     * @inheritdoc ICollateralModule
     */
    function getAccountLiquidationBoosterBalance(uint128 accountId, address collateralType)
        external
        view
        override
        returns (uint256 collateralBalance)
    {
        return Account.load(accountId).getLiquidationBoosterBalance(collateralType);
    }

}
