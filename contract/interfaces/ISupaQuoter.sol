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
     * @notice Returns exact output quote for single-hop swap.
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter);

    /**
     * @notice Returns exact output quote for multi-hop swap route.
     */
    function quoteExactInput(bytes memory path, uint128 amountIn)
        external
        returns (uint256 amountOut);

    /**
     * @notice Returns exact input quote for single-hop swap.
     */
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        returns (uint256 amountIn, uint160 sqrtPriceX96After, int24 tickAfter);

    /**
     * @notice Returns exact input quote for multi-hop swap route.
     */
    function quoteExactOutput(bytes memory path, uint128 amountOut)
        external
        returns (uint256 amountIn);
}
