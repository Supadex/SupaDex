// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "../types/Currency.sol";

/**
 * @title PeripheryErrors
 * @notice Library of zero-gas custom errors for SupaDex periphery contracts.
 */
library PeripheryErrors {
    /**
     * @dev Thrown when transaction execution happens past user-specified deadline.
     */
    error DeadlinePassed(uint256 deadline, uint256 currentTimestamp);

    /**
     * @dev Thrown when output amount is less than minAmountOut or input amount exceeds maxAmountIn.
     */
    error SlippageExceeded(uint256 expected, uint256 actual);

    /**
     * @dev Thrown when msg.value is insufficient to cover required native ETH payment.
     */
    error InsufficientETH(uint256 required, uint256 sent);

    /**
     * @dev Thrown when native ETH transfer reverts.
     */
    error ETHTransferFailed();

    /**
     * @dev Thrown when multi-hop path encoding is malformed or empty.
     */
    error InvalidPath();

    /**
     * @dev Thrown when caller is not authorized for the requested position operation.
     */
    error Unauthorized();

    /**
     * @dev Thrown when requested position token ID does not exist or has zero liquidity.
     */
    error PositionNotFound(uint256 tokenId);

    /**
     * @dev Thrown when liquidity amount is zero.
     */
    error ZeroLiquidity();

    /**
     * @dev Thrown when identical currencies are provided in a pool path.
     */
    error IdenticalCurrencies();

    /**
     * @dev Thrown when pool key has invalid parameters.
     */
    error InvalidPoolKey();

    /**
     * @dev Thrown to bubble up exact-input quote simulation results without persisting state.
     */
    error QuoteInputSimulation(uint256 amountOut, uint160 sqrtPriceX96, int24 tick);

    /**
     * @dev Thrown to bubble up exact-output quote simulation results without persisting state.
     */
    error QuoteOutputSimulation(uint256 amountIn, uint160 sqrtPriceX96, int24 tick);
}
