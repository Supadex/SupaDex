// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "./IPoolManager.sol";
import {IVault} from "./IVault.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {Currency} from "../types/Currency.sol";

/**
 * @title ISupaRouter
 * @notice Interface for the SupaDex multi-hop, multi-curve swap router.
 */
interface ISupaRouter {
    /**
     * @notice Parameters for single-pool exact input swap.
     */
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
        bool payWithClaims;
        bool receiveAsClaims;
        uint256 deadline;
    }

    /**
     * @notice Parameters for multi-hop exact input swap.
     */
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bool payWithClaims;
        bool receiveAsClaims;
        uint256 deadline;
    }

    /**
     * @notice Parameters for single-pool exact output swap.
     */
    struct ExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
        bool payWithClaims;
        bool receiveAsClaims;
        uint256 deadline;
    }

    /**
     * @notice Parameters for multi-hop exact output swap.
     */
    struct ExactOutputParams {
        bytes path;
        address recipient;
        uint128 amountOut;
        uint128 amountInMaximum;
        bool payWithClaims;
        bool receiveAsClaims;
        uint256 deadline;
    }

    /**
     * @notice Returns the immutable PoolManager address.
     */
    function poolManager() external view returns (IPoolManager);

    /**
     * @notice Returns the immutable Vault address.
     */
    function vault() external view returns (IVault);

    /**
     * @notice Executes a single-hop exact input swap.
     * @param params ExactInputSingleParams struct.
     * @return amountOut The actual amount of output token received.
     */
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /**
     * @notice Executes a multi-hop exact input swap across multiple pools/curves.
     * @param params ExactInputParams struct with encoded path.
     * @return amountOut The final amount of output token received.
     */
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    /**
     * @notice Executes a single-hop exact output swap.
     * @dev APUS-SUPADEX-039: with `sqrtPriceLimitX96 == 0` the swap delivers exactly `amountOut` or reverts with
     *      `PeripheryErrors.InsufficientOutputAmount(requested, delivered)` (Uniswap v3 parity). With an explicit price
     *      limit it may fill partially up to the limit (v3 semantics), but only if
     *      `amountIn * amountOut <= amountInMaximum * delivered` (per-unit price bound; else `SlippageExceeded`) and
     *      `delivered > 0`. The delivered amount is in the `SwapRouted` event; the return value is `amountIn` only.
     * @param params ExactOutputSingleParams struct.
     * @return amountIn The actual amount of input token spent.
     */
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    /**
     * @notice Executes a multi-hop exact output swap across multiple pools/curves.
     * @dev Every hop must deliver in full; a short hop reverts with `PeripheryErrors.InsufficientOutputAmount`.
     * @param params ExactOutputParams struct with encoded path.
     * @return amountIn The final amount of input token spent.
     */
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);
}
