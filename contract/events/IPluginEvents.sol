// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "../types/PoolId.sol";

/**
 * @title IPluginEvents
 * @notice Decoupled event logging interface for native plugins and external hooks.
 */
interface IPluginEvents {
    /**
     * @notice Emitted when the LVR Shield plugin updates a dynamic swap fee.
     */
    event DynamicFeeUpdated(
        PoolId indexed poolId,
        uint24 oldFee,
        uint24 newFee,
        uint24 volatilitySurcharge,
        uint32 timeElapsed
    );

    /**
     * @notice Emitted when high-frequency volatility is observed and recorded.
     */
    event VolatilityObserved(
        PoolId indexed poolId,
        uint32 windowSeconds,
        uint256 instantaneousVolatility,
        int24 currentTick
    );

    /**
     * @notice Emitted when Anti-JIT residency is registered for a liquidity position.
     */
    event LiquidityResidencyRecorded(
        PoolId indexed poolId,
        address indexed provider,
        bytes32 indexed positionKey,
        uint32 depositBlock,
        uint32 depositTimestamp,
        uint128 liquidity
    );

    /**
     * @notice Emitted when a JIT liquidity provider suffers a fee haircut due to early withdrawal.
     */
    event JITPenaltyLevied(
        PoolId indexed poolId,
        address indexed provider,
        bytes32 indexed positionKey,
        uint256 penaltyAmount,
        uint256 elapsedBlocks,
        uint256 requiredBlocks
    );
}
