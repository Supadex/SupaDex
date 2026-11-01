// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "./IPoolManager.sol";
import {IVault} from "./IVault.sol";
import {PoolKey} from "../types/PoolKey.sol";

/**
 * @title ISupaQuoter
 * @notice Interface for static off-chain and on-chain swap simulation and quoting.
 */
interface ISupaQuoter {
    /**
     * @notice Struct for single pool exact input quote.
     */
    struct QuoteExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    /**
     * @notice Struct for single pool exact output quote.
     */
    struct QuoteExactOutputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountOut;
        uint160 sqrtPriceLimitX96;
        bytes hookData;
    }

    /**
     * @notice Returns the PoolManager instance.
     */
    function poolManager() external view returns (IPoolManager);

    /**
     * @notice Returns the Vault instance.
     */
    function vault() external view returns (IVault);

    /**
     * @notice Returns the output of a single-hop exact-input swap.
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter);

    /**
     * @notice Same as quoteExactInputSingle, plus the LP fee (pips, 1e6 = 100%) the pool manager actually applied
     *         to this swap (plugin dynamic fee, e.g. LVR, or key.fee when the plugin returns 0).
     */
    function quoteExactInputSingleWithFee(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter, uint24 feePips);

    /**
     * @notice Returns the output of a multi-hop exact-input route.
     */
    function quoteExactInput(bytes memory path, uint128 amountIn) external returns (uint256 amountOut);

    /**
     * @notice Returns the input needed for a single-hop exact-output swap.
     * @dev APUS-SUPADEX-039: with `sqrtPriceLimitX96 == 0` the quote reverts with
     *      `PeripheryErrors.InsufficientOutputAmount(requested, deliverable)` when the pool cannot fill `amountOut`
     *      (the router would revert too). With a price limit it prices the fill up to the limit (Uniswap v3 QuoterV2
     *      semantics) and does NOT return the deliverable amount: on CLAMM a partial fill shows as
     *      `sqrtPriceX96After == sqrtPriceLimitX96`; on BIN (discrete bins) that signal is not guaranteed. Integrators
     *      that need an exact amount should quote and swap with `sqrtPriceLimitX96 == 0`.
     *      APUS-SUPADEX-041: with a price limit that allows no fill at all (nothing deliverable before the limit), the
     *      quote reverts with `PeripheryErrors.InsufficientOutputAmount(requested, 0)`, exactly as the router does.
     */
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, int24 tickAfter);

    /// @notice Same as quoteExactOutputSingle, plus the applied LP fee (pips).
    function quoteExactOutputSingleWithFee(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, int24 tickAfter, uint24 feePips);

    /**
     * @notice Returns the input needed for a multi-hop exact-output route.
     * @dev Reverts with `PeripheryErrors.InsufficientOutputAmount(requested, delivered)` if any hop cannot fill.
     */
    function quoteExactOutput(bytes memory path, uint128 amountOut) external returns (uint256 amountIn);
}
