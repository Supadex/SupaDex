// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaFeeCollector} from "../interfaces/ISupaFeeCollector.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {ISupaRoles} from "../interfaces/ISupaRoles.sol";
import {Currency} from "../types/Currency.sol";
import {FeeCollectorErrors} from "../errors/FeeCollectorErrors.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";

/**
 * @title SupaFeeCollector
 * @notice Collects accrued protocol fees from PoolManager and distributes them per governance fee split.
 */
contract SupaFeeCollector is ISupaFeeCollector, IUnlockCallback, PeripheryPayments {
    uint16 public constant BPS_DENOMINATOR = 10_000;

    IPoolManager public immutable poolManager;
    address public immutable override roles;

    address public override owner;
    uint16 public override daoTreasuryShareBps;
    uint16 public override lpStakingShareBps;
    uint16 public override insuranceReserveShareBps;
    address public override daoTreasury;
    address public override lpStaking;
    address public override insuranceReserve;

    modifier onlyOwner() {
        if (msg.sender != owner) revert FeeCollectorErrors.Unauthorized();
        _;
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner && !ISupaRoles(roles).isOperator(msg.sender)) {
            revert FeeCollectorErrors.Unauthorized();
        }
        _;
    }

    constructor(
        IPoolManager poolManager_,
        IVault vault_,
        ISupaRoles roles_,
        address initialOwner,
        address dao_,
        address staking_,
        address insurance_
    ) PeripheryPayments(vault_) {
        if (address(poolManager_) == address(0) || address(roles_) == address(0) || initialOwner == address(0)) {
            revert FeeCollectorErrors.ZeroAddress();
        }
        if (dao_ == address(0) || staking_ == address(0) || insurance_ == address(0)) {
            revert FeeCollectorErrors.ZeroAddress();
        }
        poolManager = poolManager_;
        roles = address(roles_);
        owner = initialOwner;
        daoTreasury = dao_;
        lpStaking = staking_;
        insuranceReserve = insurance_;
        daoTreasuryShareBps = 6000;
        lpStakingShareBps = 3000;
        insuranceReserveShareBps = 1000;
    }

    function setFeeSplit(uint16 daoBps, uint16 stakingBps, uint16 insuranceBps) external override onlyOwner {
        if (uint256(daoBps) + stakingBps + insuranceBps != BPS_DENOMINATOR) {
            revert FeeCollectorErrors.InvalidFeeSplit();
        }
        daoTreasuryShareBps = daoBps;
        lpStakingShareBps = stakingBps;
        insuranceReserveShareBps = insuranceBps;
        emit FeeSplitUpdated(daoBps, stakingBps, insuranceBps);
    }

    function setFeeRecipients(address dao, address staking, address insurance) external override onlyOwner {
        if (dao == address(0) || staking == address(0) || insurance == address(0)) {
            revert FeeCollectorErrors.ZeroAddress();
        }
        daoTreasury = dao;
        lpStaking = staking;
        insuranceReserve = insurance;
        emit FeeRecipientsUpdated(dao, staking, insurance);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert FeeCollectorErrors.ZeroAddress();
        owner = newOwner;
    }

    /**
     * @notice Pulls accrued protocol fees and distributes to DAO / staking / insurance.
     */
    function sweepProtocolFees(Currency[] calldata currencies, bool asClaims) external override onlyOwnerOrOperator {
        if (currencies.length == 0) revert FeeCollectorErrors.NothingToSweep();
        _vault.unlock(abi.encode(currencies, asClaims, msg.sender));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(_vault)) revert FeeCollectorErrors.Unauthorized();

        (Currency[] memory currencies, bool asClaims, address caller) =
            abi.decode(data, (Currency[], bool, address));

        uint256 len = currencies.length;
        for (uint256 i; i < len;) {
            Currency currency = currencies[i];
            uint256 accrued = poolManager.protocolFeesAccrued(currency);
            if (accrued > 0) {
                uint256 collected = poolManager.collectProtocolFees(currency, address(this), accrued);
                _distribute(currency, collected, asClaims, caller);
            }
            unchecked {
                ++i;
            }
        }
        return "";
    }

    function _distribute(Currency currency, uint256 total, bool asClaims, address caller) internal {
        if (total == 0) return;

        uint256 daoAmount = (total * daoTreasuryShareBps) / BPS_DENOMINATOR;
        uint256 stakingAmount = (total * lpStakingShareBps) / BPS_DENOMINATOR;
        uint256 insuranceAmount = total - daoAmount - stakingAmount;

        _take(currency, daoTreasury, daoAmount, asClaims);
        _take(currency, lpStaking, stakingAmount, asClaims);
        _take(currency, insuranceReserve, insuranceAmount, asClaims);

        emit ProtocolFeesSwept(caller, currency, total, daoAmount, stakingAmount, insuranceAmount, asClaims);
    }
}
