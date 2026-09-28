// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DynamicFeeLib
 * @notice Implements volatility-adaptive decaying dynamic fee calculation to mitigate LVR and capture MEV.
 */
library DynamicFeeLib {
    uint24 internal constant MAX_FEE = 100000; // 10% max fee cap (in hundredths of a bip, 1e6 scale)
    uint24 internal constant MIN_FEE = 100; // 0.01% min fee floor

    /**
     * @notice Computes updated dynamic fee based on tick movement and time decay.
     * @param baseFee The standard base fee of the pool.
     * @param lastFee The dynamic fee computed at the previous swap.
     * @param tickDelta Absolute tick movement since last swap.
     * @param timeElapsed Seconds elapsed since last swap.
     * @param decayHalfLife Seconds for elevated fee to decay by half (e.g. 12 seconds / 1 block).
     * @return updatedFee The new dynamic swap fee.
     */
    function computeDynamicFee(
        uint24 baseFee,
        uint24 lastFee,
        uint24 tickDelta,
        uint32 timeElapsed,
        uint32 decayHalfLife
    ) internal pure returns (uint24 updatedFee) {
        // 1. Time decay from previous elevated fee
        uint256 decayedFee = baseFee;
        if (lastFee > baseFee && decayHalfLife > 0) {
            // Decay factor = 1 / (2 ^ (timeElapsed / decayHalfLife))
            uint256 periods = timeElapsed / decayHalfLife;
            if (periods < 16) {
                uint256 excess = lastFee - baseFee;
                decayedFee = baseFee + (excess >> periods);
            }
        }

        // 2. Volatility spike from current trade price movement
        // Scale tick delta: each 10 ticks (0.1% price movement) adds 5 bps (500 units)
        uint256 volatilitySurcharge = (uint256(tickDelta) * 50);

        uint256 total = decayedFee + volatilitySurcharge;

        if (total > MAX_FEE) {
            updatedFee = MAX_FEE;
        } else if (total < MIN_FEE) {
            updatedFee = MIN_FEE;
        } else {
            updatedFee = uint24(total);
        }
    }
}
