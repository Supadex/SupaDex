// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";
import {IFeeCollectorEvents} from "../events/IFeeCollectorEvents.sol";

/**
 * @title ISupaFeeCollector
 * @notice Protocol fee split configuration and batch sweep surface.
 */
interface ISupaFeeCollector is IFeeCollectorEvents {
    function daoTreasuryShareBps() external view returns (uint16);
    function lpStakingShareBps() external view returns (uint16);
    function insuranceReserveShareBps() external view returns (uint16);
    function daoTreasury() external view returns (address);
    function lpStaking() external view returns (address);
    function insuranceReserve() external view returns (address);
    function owner() external view returns (address);
    function roles() external view returns (address);

    function setFeeSplit(uint16 daoBps, uint16 stakingBps, uint16 insuranceBps) external;
    function setFeeRecipients(address dao, address staking, address insurance) external;
    function sweepProtocolFees(Currency[] calldata currencies, bool asClaims) external;
}
