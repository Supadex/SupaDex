// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaRouter} from "../interfaces/ISupaRouter.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {IPeripheryEvents} from "../events/IPeripheryEvents.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {Multicall} from "./base/Multicall.sol";
import {PathKeyLib} from "./libraries/PathKeyLib.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PeripheryErrors} from "../errors/PeripheryErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";

/**
 * @title SupaRouter
 * @notice Production-grade swap router supporting single-hop & multi-hop trades across
 * CLAMM, BinAMM, and StableAMM pools with transient delta aggregation and ERC-6909 claim support.
 */
contract SupaRouter is ISupaRouter, IUnlockCallback, IPeripheryEvents, PeripheryPayments, Multicall {
    using PathKeyLib for bytes;
    using CurrencyLibrary for Currency;

    /**
     * @dev Internal action discriminators for unlock callback routing.
     */
    enum Action {
        EXACT_INPUT_SINGLE,
        EXACT_INPUT_MULTI,
        EXACT_OUTPUT_SINGLE,
        EXACT_OUTPUT_MULTI
    }

    /**
     * @inheritdoc ISupaRouter
     */
    IPoolManager public immutable override poolManager;

    constructor(IPoolManager _poolManager, IVault _vaultContract) PeripheryPayments(_vaultContract) {
        poolManager = _poolManager;
    }

    /**
     * @inheritdoc ISupaRouter
     */
    function vault() public view override(ISupaRouter, PeripheryPayments) returns (IVault) {
        return _vault;
    }

    /**
     * @dev Modifier verifying that unlock callback originates strictly from the authorized Vault.
     */
    modifier onlyVault() {
        if (msg.sender != address(_vault)) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @inheritdoc ISupaRouter
     */
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        bytes memory result = _vault.unlock(abi.encode(Action.EXACT_INPUT_SINGLE, msg.sender, params));
        amountOut = abi.decode(result, (uint256));

        // Refund any residual native ETH remaining in contract
        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaRouter
     */
    function exactInput(ExactInputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountOut)
    {
        bytes memory result = _vault.unlock(abi.encode(Action.EXACT_INPUT_MULTI, msg.sender, params));
        amountOut = abi.decode(result, (uint256));

        // Refund any residual native ETH remaining in contract
        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaRouter
     */
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        bytes memory result = _vault.unlock(abi.encode(Action.EXACT_OUTPUT_SINGLE, msg.sender, params));
        amountIn = abi.decode(result, (uint256));

        // Refund any residual native ETH remaining in contract
        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaRouter
     */
    function exactOutput(ExactOutputParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amountIn)
    {
        bytes memory result = _vault.unlock(abi.encode(Action.EXACT_OUTPUT_MULTI, msg.sender, params));
        amountIn = abi.decode(result, (uint256));

        // Refund any residual native ETH remaining in contract
        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external override onlyVault returns (bytes memory) {
        Action action = abi.decode(data, (Action));

        if (action == Action.EXACT_INPUT_SINGLE) {
            (, address payer, ExactInputSingleParams memory params) =
                abi.decode(data, (Action, address, ExactInputSingleParams));
            return abi.encode(_handleExactInputSingle(payer, params));
        } else if (action == Action.EXACT_INPUT_MULTI) {
            (, address payer, ExactInputParams memory params) = abi.decode(data, (Action, address, ExactInputParams));
            return abi.encode(_handleExactInputMulti(payer, params));
        } else if (action == Action.EXACT_OUTPUT_SINGLE) {
            (, address payer, ExactOutputSingleParams memory params) =
                abi.decode(data, (Action, address, ExactOutputSingleParams));
            return abi.encode(_handleExactOutputSingle(payer, params));
        } else {
            (, address payer, ExactOutputParams memory params) = abi.decode(data, (Action, address, ExactOutputParams));
            return abi.encode(_handleExactOutputMulti(payer, params));
        }
    }

    /**
     * @dev Internal execution for single-hop exact input swap.
     */
    function _handleExactInputSingle(address payer, ExactInputSingleParams memory params)
        internal
        returns (uint256 amountOut)
    {
        Currency inputCurrency = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0;

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: int256(uint256(params.amountIn)),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(params.poolKey, swapParams, params.hookData);

        uint256 actualAmountIn;
        if (params.zeroForOne) {
            actualAmountIn = uint256(uint128(delta.amount0()));
            amountOut = uint256(uint128(-delta.amount1()));
        } else {
            actualAmountIn = uint256(uint128(delta.amount1()));
            amountOut = uint256(uint128(-delta.amount0()));
        }

        if (amountOut < params.amountOutMinimum) {
            revert PeripheryErrors.SlippageExceeded(params.amountOutMinimum, amountOut);
        }

        // Settle input token debt with Vault
        _pay(inputCurrency, payer, actualAmountIn, params.payWithClaims);

        // Take output token credit from Vault
        _take(outputCurrency, params.recipient, amountOut, params.receiveAsClaims);

        emit SwapRouted(payer, params.recipient, inputCurrency, outputCurrency, actualAmountIn, amountOut);
    }

    /**
     * @dev Internal execution for multi-hop exact input swap with transient delta aggregation.
     */
    function _handleExactInputMulti(address payer, ExactInputParams memory params)
        internal
        returns (uint256 amountOut)
    {
        bytes memory path = params.path;
        if (path.length < 67) revert PeripheryErrors.InvalidPath();

        (, Currency firstIn,,) = path.getFirstPoolKey();
        Currency inputCurrency = firstIn;
        uint256 currentAmountIn = params.amountIn;
        Currency currentOutputCurrency;

        while (true) {
            (PoolKey memory key,, Currency hopOut, bool zeroForOne) = path.getFirstPoolKey();
            currentOutputCurrency = hopOut;

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: int256(currentAmountIn), sqrtPriceLimitX96: 0
            });

            BalanceDelta delta = poolManager.swap(key, swapParams, "");
            currentAmountIn = uint256(uint128(zeroForOne ? -delta.amount1() : -delta.amount0()));

            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                break;
            }
        }

        amountOut = currentAmountIn;
        if (amountOut < params.amountOutMinimum) {
            revert PeripheryErrors.SlippageExceeded(params.amountOutMinimum, amountOut);
        }

        _pay(inputCurrency, payer, params.amountIn, params.payWithClaims);
        _take(currentOutputCurrency, params.recipient, amountOut, params.receiveAsClaims);

        emit SwapRouted(payer, params.recipient, inputCurrency, currentOutputCurrency, params.amountIn, amountOut);
    }

    /**
     * @dev Internal execution for single-hop exact output swap.
     */
    function _handleExactOutputSingle(address payer, ExactOutputSingleParams memory params)
        internal
        returns (uint256 amountIn)
    {
        Currency inputCurrency = params.zeroForOne ? params.poolKey.currency0 : params.poolKey.currency1;
        Currency outputCurrency = params.zeroForOne ? params.poolKey.currency1 : params.poolKey.currency0;

        IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
            zeroForOne: params.zeroForOne,
            amountSpecified: -int256(uint256(params.amountOut)),
            sqrtPriceLimitX96: params.sqrtPriceLimitX96
        });

        BalanceDelta delta = poolManager.swap(params.poolKey, swapParams, params.hookData);

        uint256 actualAmountOut;
        if (params.zeroForOne) {
            amountIn = uint256(uint128(delta.amount0()));
            actualAmountOut = uint256(uint128(-delta.amount1()));
        } else {
            amountIn = uint256(uint128(delta.amount1()));
            actualAmountOut = uint256(uint128(-delta.amount0()));
        }

        if (amountIn > params.amountInMaximum) {
            revert PeripheryErrors.SlippageExceeded(params.amountInMaximum, amountIn);
        }

        _pay(inputCurrency, payer, amountIn, params.payWithClaims);
        _take(outputCurrency, params.recipient, actualAmountOut, params.receiveAsClaims);

        emit SwapRouted(payer, params.recipient, inputCurrency, outputCurrency, amountIn, actualAmountOut);
    }

    /**
     * @dev Internal execution for multi-hop exact output swap.
     */
    function _handleExactOutputMulti(address payer, ExactOutputParams memory params)
        internal
        returns (uint256 amountIn)
    {
        bytes memory path = params.path;
        if (path.length < 67) revert PeripheryErrors.InvalidPath();

        (, Currency targetOut,,) = path.getFirstPoolKey();
        Currency outputCurrency = targetOut;
        uint256 currentAmountOut = params.amountOut;
        Currency currentInputCurrency;

        while (true) {
            (PoolKey memory key,, Currency hopIn, bool zeroForOne) = path.getFirstPoolKey();
            currentInputCurrency = hopIn;

            bool swapZeroForOne = !zeroForOne;

            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: swapZeroForOne, amountSpecified: -int256(currentAmountOut), sqrtPriceLimitX96: 0
            });

            BalanceDelta delta = poolManager.swap(key, swapParams, "");
            currentAmountOut = uint256(uint128(swapZeroForOne ? delta.amount0() : delta.amount1()));

            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                break;
            }
        }

        amountIn = currentAmountOut;
        if (amountIn > params.amountInMaximum) {
            revert PeripheryErrors.SlippageExceeded(params.amountInMaximum, amountIn);
        }

        _pay(currentInputCurrency, payer, amountIn, params.payWithClaims);
        _take(outputCurrency, params.recipient, params.amountOut, params.receiveAsClaims);

        emit SwapRouted(payer, params.recipient, currentInputCurrency, outputCurrency, amountIn, params.amountOut);
    }
}
