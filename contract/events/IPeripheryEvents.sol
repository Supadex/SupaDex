// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";
import {PoolId} from "../types/PoolId.sol";

/**
 * @title IPeripheryEvents
 * @notice Decoupled event definitions for SupaDex periphery contracts.
 */
interface IPeripheryEvents {
    /**
     * @notice Emitted upon successful execution of a single-hop or multi-hop swap.
     */
    event SwapRouted(
        address indexed sender,
        address indexed recipient,
        Currency indexed currencyIn,
        Currency currencyOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /**
     * @notice Emitted when a new tokenized liquidity position is minted.
     */
    event PositionMinted(
        uint256 indexed tokenId,
        address indexed owner,
        PoolId indexed poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /**
     * @notice Emitted when liquidity is increased in an existing position NFT.
     */
    event LiquidityIncreased(uint256 indexed tokenId, uint128 liquidityAdded, uint256 amount0, uint256 amount1);

    /**
     * @notice Emitted when liquidity is removed from an existing position NFT.
     */
    event LiquidityDecreased(uint256 indexed tokenId, uint128 liquidityRemoved, uint256 amount0, uint256 amount1);

    /**
     * @notice Emitted when accrued LP fees are collected from a position NFT.
     */
    event FeesCollected(uint256 indexed tokenId, address indexed recipient, uint256 amount0, uint256 amount1);

    /**
     * @notice Emitted when accrued swap fees are synced into a position's tokensOwed.
     */
    event FeesSynced(uint256 indexed tokenId, uint256 fees0, uint256 fees1);

    /**
     * @notice Emitted when an empty position NFT is burned.
     */
    event PositionBurned(uint256 indexed tokenId, address indexed owner);

    /**
     * @notice Emitted when physical tokens are deposited and ERC-6909 claims minted.
     */
    event ClaimDeposited(address indexed sender, address indexed to, Currency indexed currency, uint256 amount);

    /**
     * @notice Emitted when ERC-6909 claims are redeemed for physical tokens.
     */
    event ClaimWithdrawn(address indexed sender, address indexed to, Currency indexed currency, uint256 amount);
}
