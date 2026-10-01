// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title IFeeCollectorEvents
 * @notice Events for protocol fee collection and distribution.
 */
interface IFeeCollectorEvents {
    event FeeSplitUpdated(uint16 daoTreasuryShareBps, uint16 lpStakingShareBps, uint16 insuranceReserveShareBps);

    event FeeRecipientsUpdated(address daoTreasury, address lpStaking, address insuranceReserve);

    event ProtocolFeesSwept(
        address indexed caller,
        Currency indexed currency,
        uint256 totalAmount,
        uint256 daoAmount,
        uint256 stakingAmount,
        uint256 insuranceAmount,
        bool asClaims
    );
}
