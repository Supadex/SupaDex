// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {Slot0} from "../types/Slot0.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {IPoolManager} from "./IPoolManager.sol";

/**
 * @title ICurveEngine
 * @notice Pluggable curve engine interface allowing SupaDex to execute multiple curve invariants uniformly.
 */
interface ICurveEngine {
    /**
     * @notice Initializes pool curve state.
     */
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    /**
     * @notice Modifies liquidity for the curve.
     */
    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued);

    /**
     * @notice Executes a swap according to the curve mathematical invariant.
     * @param protocolFee Protocol take rate in hundredths of a bip of the swap fee amount.
     * @return swapDelta Net token delta from the swap.
     * @return protocolFeeAmount Protocol take from the input-side fee (0 if protocolFee unset).
     */
    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount);

    /**
     * @notice Returns current Slot0 state for a pool.
     */
    function getSlot0(PoolId id) external view returns (Slot0);

    /**
     * @notice Returns active liquidity for a pool.
     */
    function getLiquidity(PoolId id) external view returns (uint128);
}
