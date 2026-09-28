// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaQuoter} from "../interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {PathKeyLib} from "./libraries/PathKeyLib.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {Currency} from "../types/Currency.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../types/Slot0.sol";
import {PeripheryErrors} from "../errors/PeripheryErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";

/**
 * @title SupaQuoter
 * @notice Production-grade off-chain and on-chain swap quoter executing zero-state-change simulations.
 */
contract SupaQuoter is ISupaQuoter, IUnlockCallback {
    using PathKeyLib for bytes;
    using Slot0Library for Slot0;

    enum Action {
        QUOTE_INPUT_SINGLE,
        QUOTE_INPUT_MULTI,
        QUOTE_OUTPUT_SINGLE,
        QUOTE_OUTPUT_MULTI
    }

    /**
     * @inheritdoc ISupaQuoter
     */
    IPoolManager public immutable override poolManager;

    /**
     * @inheritdoc ISupaQuoter
     */
    IVault public immutable override vault;

    constructor(IPoolManager _poolManager, IVault _vault) {
        poolManager = _poolManager;
        vault = _vault;
    }

    /**
     * @dev Modifier verifying that unlock callback originates strictly from the authorized Vault.
     */
    modifier onlyVault() {
        if (msg.sender != address(vault)) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @inheritdoc ISupaQuoter
     */
    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        override
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        try this.quoteExactInputSingleInternal(params) {}
        catch (bytes memory reason) {
            return _parseQuoteInputResult(reason);
        }
    }

    /**
     * @notice Internal execution endpoint called via `this` to capture revert payload.
     */
    function quoteExactInputSingleInternal(QuoteExactInputSingleParams memory params) external {
        vault.unlock(abi.encode(Action.QUOTE_INPUT_SINGLE, params));
    }

    /**
     * @inheritdoc ISupaQuoter
     */
    function quoteExactInput(bytes memory path, uint128 amountIn)
        external
        override
        returns (uint256 amountOut)
    {
        try this.quoteExactInputInternal(path, amountIn) {}
        catch (bytes memory reason) {
            (amountOut, , ) = _parseQuoteInputResult(reason);
            return amountOut;
        }
    }

    /**
     * @notice Internal multi-hop exact input simulation endpoint.
     */
    function quoteExactInputInternal(bytes memory path, uint128 amountIn) external {
        vault.unlock(abi.encode(Action.QUOTE_INPUT_MULTI, path, amountIn));
    }

    /**
     * @inheritdoc ISupaQuoter
     */
    function quoteExactOutputSingle(QuoteExactOutputSingleParams memory params)
        external
        override
        returns (uint256 amountIn, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        try this.quoteExactOutputSingleInternal(params) {}
        catch (bytes memory reason) {
            return _parseQuoteOutputResult(reason);
        }
    }

    /**
     * @notice Internal execution endpoint for exact output simulation.
     */
    function quoteExactOutputSingleInternal(QuoteExactOutputSingleParams memory params) external {
        vault.unlock(abi.encode(Action.QUOTE_OUTPUT_SINGLE, params));
    }

    /**
     * @inheritdoc ISupaQuoter
     */
    function quoteExactOutput(bytes memory path, uint128 amountOut)
        external
        override
        returns (uint256 amountIn)
    {
        try this.quoteExactOutputInternal(path, amountOut) {}
        catch (bytes memory reason) {
            (amountIn, , ) = _parseQuoteOutputResult(reason);
            return amountIn;
        }
    }

    /**
     * @notice Internal multi-hop exact output simulation endpoint.
     */
    function quoteExactOutputInternal(bytes memory path, uint128 amountOut) external {
        vault.unlock(abi.encode(Action.QUOTE_OUTPUT_MULTI, path, amountOut));
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external override onlyVault returns (bytes memory) {
        Action action = abi.decode(data, (Action));

        if (action == Action.QUOTE_INPUT_SINGLE) {
            (, QuoteExactInputSingleParams memory params) =
                abi.decode(data, (Action, QuoteExactInputSingleParams));

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(uint256(params.amountIn)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });

            BalanceDelta delta = poolManager.swap(params.poolKey, swapParams, params.hookData);
            uint256 amountOut = uint256(uint128(params.zeroForOne ? -delta.amount1() : -delta.amount0()));
            Slot0 slot0 = poolManager.getSlot0(params.poolKey.toId());

            revert PeripheryErrors.QuoteInputSimulation(amountOut, slot0.sqrtPriceX96(), slot0.tick());
        } else if (action == Action.QUOTE_INPUT_MULTI) {
            (, bytes memory path, uint128 amountIn) =
                abi.decode(data, (Action, bytes, uint128));

            uint256 currentAmountIn = amountIn;
            Slot0 lastSlot0;

            while (true) {
                (PoolKey memory key, , , bool zeroForOne) = path.getFirstPoolKey();

                IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(currentAmountIn),
                    sqrtPriceLimitX96: 0
                });

                BalanceDelta delta = poolManager.swap(key, swapParams, "");
                currentAmountIn = uint256(uint128(zeroForOne ? -delta.amount1() : -delta.amount0()));
                lastSlot0 = poolManager.getSlot0(key.toId());

                if (path.hasMultiplePools()) {
                    path = path.skipToken();
                } else {
                    break;
                }
            }

            revert PeripheryErrors.QuoteInputSimulation(currentAmountIn, lastSlot0.sqrtPriceX96(), lastSlot0.tick());
        } else if (action == Action.QUOTE_OUTPUT_SINGLE) {
            (, QuoteExactOutputSingleParams memory params) =
                abi.decode(data, (Action, QuoteExactOutputSingleParams));

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: params.zeroForOne,
                amountSpecified: -int256(uint256(params.amountOut)),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            });

            BalanceDelta delta = poolManager.swap(params.poolKey, swapParams, params.hookData);
            uint256 amountIn = uint256(uint128(params.zeroForOne ? delta.amount0() : delta.amount1()));
            Slot0 slot0 = poolManager.getSlot0(params.poolKey.toId());

            revert PeripheryErrors.QuoteOutputSimulation(amountIn, slot0.sqrtPriceX96(), slot0.tick());
        } else {
            (, bytes memory path, uint128 amountOut) =
                abi.decode(data, (Action, bytes, uint128));

            uint256 currentAmountOut = amountOut;
            Slot0 lastSlot0;

            while (true) {
                (PoolKey memory key, , , bool zeroForOne) = path.getFirstPoolKey();
                bool swapZeroForOne = !zeroForOne;

                IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                    zeroForOne: swapZeroForOne,
                    amountSpecified: -int256(currentAmountOut),
                    sqrtPriceLimitX96: 0
                });

                BalanceDelta delta = poolManager.swap(key, swapParams, "");
                currentAmountOut = uint256(uint128(swapZeroForOne ? delta.amount0() : delta.amount1()));
                lastSlot0 = poolManager.getSlot0(key.toId());

                if (path.hasMultiplePools()) {
                    path = path.skipToken();
                } else {
                    break;
                }
            }

            revert PeripheryErrors.QuoteOutputSimulation(currentAmountOut, lastSlot0.sqrtPriceX96(), lastSlot0.tick());
        }
    }

    /**
     * @dev Decodes exact input simulation results from revert error payload.
     */
    function _parseQuoteInputResult(bytes memory reason)
        internal
        pure
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length < 4) revert PeripheryErrors.InvalidPath();
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }

        if (selector == PeripheryErrors.QuoteInputSimulation.selector) {
            assembly {
                let dataPtr := add(reason, 36)
                amountOut := mload(dataPtr)
                sqrtPriceX96After := mload(add(dataPtr, 32))
                tickAfter := mload(add(dataPtr, 64))
            }
        } else {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    /**
     * @dev Decodes exact output simulation results from revert error payload.
     */
    function _parseQuoteOutputResult(bytes memory reason)
        internal
        pure
        returns (uint256 amountIn, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        if (reason.length < 4) revert PeripheryErrors.InvalidPath();
        bytes4 selector;
        assembly {
            selector := mload(add(reason, 32))
        }

        if (selector == PeripheryErrors.QuoteOutputSimulation.selector) {
            assembly {
                let dataPtr := add(reason, 36)
                amountIn := mload(dataPtr)
                sqrtPriceX96After := mload(add(dataPtr, 32))
                tickAfter := mload(add(dataPtr, 64))
            }
        } else {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
