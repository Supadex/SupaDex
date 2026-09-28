// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "./Currency.sol";
import {PoolId} from "./PoolId.sol";

/**
 * @notice Enum defining supported AMM curve mathematical primitives.
 */
enum CurveType {
    CLAMM, // 0: Concentrated Liquidity AMM (Uniswap v3/v4 tick math)
    BIN_AMM, // 1: Discretized Bin AMM (Zero-slippage within active bin)
    STABLE_AMM // 2: Stableswap Amplified Invariant
}

/**
 * @title PoolKey
 * @notice Struct uniquely identifying a SupaDex AMM pool instance.
 */
struct PoolKey {
    /**
     * @dev First currency of the pair (strictly currency0 < currency1).
     */
    Currency currency0;
    /**
     * @dev Second currency of the pair.
     */
    Currency currency1;
    /**
     * @dev Base swap fee in hundredths of a bip (1e-6, e.g. 3000 = 0.30%).
     */
    uint24 fee;
    /**
     * @dev Tick spacing or bin step granularity.
     */
    int24 tickSpacing;
    /**
     * @dev Address of the attached native plugin or external hook (address(0) if none).
     */
    address plugin;
    /**
     * @dev AMM curve math model.
     */
    CurveType curveType;
}

using {PoolKeyLibrary.toId} for PoolKey global;

library PoolKeyLibrary {
    /**
     * @notice Computes the unique PoolId for a given PoolKey.
     */
    function toId(PoolKey memory poolKey) internal pure returns (PoolId) {
        return PoolId.wrap(keccak256(abi.encode(poolKey)));
    }
}
