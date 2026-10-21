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
     * @notice Returns the authorized pool manager (immutably bound at construction).
     */
    function poolManager() external view returns (address);

    /**
     * @notice Initializes pool curve state.
     * @param initParams Curve-specific creation parameters. CLAMM / BIN: must be empty. STABLE: abi.encode(uint256 A)
     * (initial amplification chosen by the pool creator, Curve-factory style; see ADR-0007 rev. 2).
     */
    function initialize(PoolKey memory key, uint160 sqrtPriceX96, bytes memory initParams)
        external
        returns (int24 tick);

    /**
     * @notice Modifies liquidity for the curve.
     * @param owner Position owner keyed into storage (must be manager's msg.sender).
     */
    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
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
     * @notice Credits donated tokens to active in-range LPs via fee growth.
     * @dev Reverts if active liquidity is zero and either amount is non-zero.
     */
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external;

    /**
     * @notice Returns current Slot0 state for a pool.
     */
    function getSlot0(PoolId id) external view returns (Slot0);

    /**
     * @notice Returns active liquidity for a pool.
     */
    function getLiquidity(PoolId id) external view returns (uint128);
}
