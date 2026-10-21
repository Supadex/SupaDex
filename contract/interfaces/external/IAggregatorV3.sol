// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IAggregatorV3
 * @notice Minimal Chainlink-style price feed interface consumed by LVRShieldPlugin (ADR-0009).
 * @dev SupaDex never trusts this blindly: every read is a gas-capped staticcall with return-size,
 *      sign, staleness (heartbeat), future-timestamp and deviation-sanity checks; any failure takes the
 *      documented fallback-fee path instead of reverting the swap. Mocks are used in tests only.
 */
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
