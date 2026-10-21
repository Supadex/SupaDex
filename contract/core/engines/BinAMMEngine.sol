// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICurveEngine} from "../../interfaces/ICurveEngine.sol";
import {IPoolManager} from "../../interfaces/IPoolManager.sol";
import {PoolKey} from "../../types/PoolKey.sol";
import {PoolId} from "../../types/PoolId.sol";
import {BalanceDelta, toBalanceDelta} from "../../types/BalanceDelta.sol";
import {Slot0, Slot0Library} from "../../types/Slot0.sol";
import {Position} from "../../types/Position.sol";
import {PoolErrors} from "../../errors/PoolErrors.sol";
import {BinMathLib} from "../../libraries/BinMathLib.sol";
import {TreeBitmapLib} from "../../libraries/TreeBitmapLib.sol";
import {TickMathLib} from "../../libraries/TickMathLib.sol";
import {SafeCastLib} from "../../libraries/SafeCastLib.sol";
import {FullMathLib} from "../../libraries/FullMathLib.sol";
import {ProtocolFeeLib} from "../../libraries/ProtocolFeeLib.sol";

/**
 * @title BinAMMEngine
 * @notice Multi-bin discretized-liquidity AMM (Liquidity-Book style) with constant-sum pricing inside each bin,
 * bounded O(1) bin traversal and per-bin fee growth accrual to LP positions.
 * @dev Remediation-2 Issue 1 (ADR-0006, supersedes the ADR-0004 gate):
 *  - Bin `id` is a signed int24; price(id) = (1 + binStep/1e4)^id in Q128 (raw token1 per raw token0), computed in
 *    O(log |id|). `PoolKey.tickSpacing` carries the bin step, bounded to [1, 200] bps. slot0.tick = active bin id,
 *    slot0.sqrtPriceX96 = sqrt(price(active id)).
 *  - Composition: bins above the active bin hold only token0, bins below hold only token1, the active bin may hold
 *    both. Swaps trade at the bin price until the bin's output reserve is exhausted, then jump to the next bin
 *    holding liquidity in the swap direction, found in O(1) via a 3-level `TreeBitmapLib` (no empty-bin walking).
 *  - Positions: (owner, binLower = tickLower, binUpper = tickUpper inclusive, salt). `liquidityDelta` is the number
 *    of SHARES minted / burned in EVERY bin of the range (uniform-shares distribution; other shapes are built by
 *    composing several positions). Width is capped at MAX_BINS_PER_POSITION (bounded iteration).
 *  - Shares: an existing bin charges ceil(shares * reserve / totalShares) of each token on add and pays
 *    floor(...) on remove (add->remove can never profit). An empty bin is seeded with value = shares in token1
 *    units at the bin price: above active -> token0 only, below -> token1 only, active -> half / half by value.
 *  - Fees: the LP fee of a swap step accrues to the traded bin's fee growth per share. Because a position holds
 *    the same shares in every bin of its range, its fees are shares * (sum of bin growth - checkpoint); the
 *    checkpoint is the range sum stored in Position.feeGrowthInside{0,1}LastX128 (mod 2^256 arithmetic).
 *  - Value per share in a bin never decreases: swaps at the bin price round in favour of the bin, and fees are
 *    paid outside reserves (fee growth), so there is no share-inflation / donation vector.
 */
contract BinAMMEngine is ICurveEngine {
    using Slot0Library for Slot0;
    using TreeBitmapLib for TreeBitmapLib.Tree;

    uint256 internal constant Q128 = 1 << 128;
    uint256 internal constant SCALE = 1 << 128;
    uint24 internal constant MAX_FEE_PIPS = 1_000_000;
    /// @notice Max bins a single position may span (gas-bounded add / remove / fee accounting).
    uint256 public constant MAX_BINS_PER_POSITION = 64;

    address public immutable override poolManager;

    struct Bin {
        uint128 reserve0;
        uint128 reserve1;
        uint128 totalShares;
        uint256 feeGrowth0X128;
        uint256 feeGrowth1X128;
    }

    struct BinPoolState {
        Slot0 slot0;
        int24 activeId;
        uint16 binStep;
        TreeBitmapLib.Tree tree;
        mapping(int24 => Bin) bins;
        mapping(bytes32 => Position.Info) positions;
    }

    mapping(PoolId => BinPoolState) internal pools;

    modifier onlyPoolManager() {
        if (msg.sender != poolManager) revert PoolErrors.NotPoolManager();
        _;
    }

    constructor(address _poolManager) {
        if (_poolManager == address(0)) revert PoolErrors.NotPoolManager();
        poolManager = _poolManager;
    }

    // ------------------------------------------------------------------ price helpers

    /// @notice Q128 price of bin `id` for `binStep`; reverts if the price leaves the TickMath range.
    function getPriceFromId(int24 id, uint16 binStep) public pure returns (uint256 priceX128) {
        if (!BinMathLib.isIdWithinBound(id, binStep)) revert PoolErrors.BinIdOutOfBounds(id);
        priceX128 = BinMathLib.getPriceFromSignedId(id, binStep);
        uint256 sqrtP = BinMathLib.priceX128ToSqrtPriceX96(priceX128);
        if (sqrtP <= TickMathLib.MIN_SQRT_RATIO || sqrtP >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.BinIdOutOfBounds(id);
        }
    }

    function _sqrtPriceOf(uint256 priceX128) internal pure returns (uint160) {
        return uint160(BinMathLib.priceX128ToSqrtPriceX96(priceX128));
    }

    /// @dev Largest |id| that can pass `isIdWithinBound` for this step.
    function _maxAbsId(uint16 binStep) internal pure returns (int24) {
        uint256 n = BinMathLib.MAX_ID_STEP_PRODUCT / uint256(binStep);
        if (n > uint256(uint24(TickMathLib.MAX_TICK))) n = uint256(uint24(TickMathLib.MAX_TICK));
        return int24(int256(n));
    }

    /**
     * @notice Largest bin id whose price is <= `priceX128` (binary search, ~21 O(log) price evaluations).
     * @dev Searches the overflow-safe id interval; callers validate the result with `getPriceFromId`.
     */
    function getIdFromPrice(uint256 priceX128, uint16 binStep) public pure returns (int24) {
        int24 maxAbs = _maxAbsId(binStep);
        int24 lo = -maxAbs;
        int24 hi = maxAbs;
        if (BinMathLib.getPriceFromSignedId(lo, binStep) > priceX128) return lo;
        while (lo < hi) {
            int24 mid = lo + (hi - lo + 1) / 2;
            if (BinMathLib.getPriceFromSignedId(mid, binStep) <= priceX128) lo = mid;
            else hi = mid - 1;
        }
        return lo;
    }

    // ------------------------------------------------------------------ initialize

    function initialize(PoolKey memory key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (int24 tick)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (pool.slot0.isInitialized()) revert PoolErrors.PoolAlreadyInitialized(id);
        if (key.fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(key.fee);
        if (key.tickSpacing < int24(uint24(BinMathLib.MIN_BIN_STEP)) || key.tickSpacing > int24(uint24(BinMathLib.MAX_BIN_STEP))) {
            revert PoolErrors.InvalidBinStep(key.tickSpacing);
        }
        if (sqrtPriceX96 <= TickMathLib.MIN_SQRT_RATIO || sqrtPriceX96 >= TickMathLib.MAX_SQRT_RATIO) {
            revert PoolErrors.PriceLimitOutOfBounds(sqrtPriceX96);
        }
        uint16 binStep = uint16(uint24(key.tickSpacing));
        int24 activeId = getIdFromPrice(BinMathLib.getPriceX128FromSqrtPriceX96(sqrtPriceX96), binStep);

        pool.binStep = binStep;
        pool.activeId = activeId;
        pool.slot0 = Slot0Library.pack(_sqrtPriceOf(getPriceFromId(activeId, binStep)), activeId, 0, key.fee, true);
        tick = activeId;
    }

    // ------------------------------------------------------------------ liquidity

    struct ModifyVars {
        int24 activeId;
        uint16 binStep;
        uint256 amount0;
        uint256 amount1;
        uint256 sumGrowth0;
        uint256 sumGrowth1;
    }

    function modifyLiquidity(PoolKey memory key, IPoolManager.ModifyLiquidityParams memory params, address owner)
        external
        override
        onlyPoolManager
        returns (BalanceDelta callerDelta, BalanceDelta feesAccrued)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        _checkRange(params.tickLower, params.tickUpper, pool.binStep);

        Position.Info storage position =
            pool.positions[Position.getKey(owner, params.tickLower, params.tickUpper, params.salt)];
        uint128 sharesBefore = position.liquidity;

        ModifyVars memory v;
        v.activeId = pool.activeId;
        v.binStep = pool.binStep;

        int256 delta = params.liquidityDelta;
        uint128 shares = delta >= 0 ? SafeCastLib.toUint128(uint256(delta)) : SafeCastLib.toUint128(uint256(-delta));
        if (delta < 0 && sharesBefore < shares) revert PoolErrors.LiquidityOverflow();

        for (int24 b = params.tickLower; b <= params.tickUpper; b++) {
            Bin storage bin = pool.bins[b];
            // Fee growth is read before the edit (edits never change growth).
            unchecked {
                v.sumGrowth0 += bin.feeGrowth0X128;
                v.sumGrowth1 += bin.feeGrowth1X128;
            }
            if (delta > 0) _addToBin(pool, bin, b, shares, v);
            else if (delta < 0) _removeFromBin(pool, bin, b, shares, v);
        }

        uint256 fees0;
        uint256 fees1;
        if (sharesBefore > 0) {
            unchecked {
                fees0 = FullMathLib.mulDiv(sharesBefore, v.sumGrowth0 - position.feeGrowthInside0LastX128, Q128);
                fees1 = FullMathLib.mulDiv(sharesBefore, v.sumGrowth1 - position.feeGrowthInside1LastX128, Q128);
            }
        }
        position.feeGrowthInside0LastX128 = v.sumGrowth0;
        position.feeGrowthInside1LastX128 = v.sumGrowth1;
        position.lastModifiedBlock = uint64(block.number);

        if (delta > 0) {
            position.liquidity = sharesBefore + shares;
            callerDelta = toBalanceDelta(
                SafeCastLib.toInt128(SafeCastLib.toInt256(v.amount0)),
                SafeCastLib.toInt128(SafeCastLib.toInt256(v.amount1))
            );
        } else if (delta < 0) {
            position.liquidity = sharesBefore - shares;
            callerDelta = toBalanceDelta(
                -SafeCastLib.toInt128(SafeCastLib.toInt256(v.amount0)),
                -SafeCastLib.toInt128(SafeCastLib.toInt256(v.amount1))
            );
        }
        feesAccrued = toBalanceDelta(
            SafeCastLib.toInt128(SafeCastLib.toInt256(fees0)), SafeCastLib.toInt128(SafeCastLib.toInt256(fees1))
        );
    }

    function _checkRange(int24 lower, int24 upper, uint16 binStep) internal pure {
        if (lower > upper) revert PoolErrors.TicksMisordered(lower, upper);
        if (uint256(int256(upper) - int256(lower)) + 1 > MAX_BINS_PER_POSITION) {
            revert PoolErrors.BinRangeTooWide(lower, upper, MAX_BINS_PER_POSITION);
        }
        // Bounds: both ends must have a valid price (prices are monotone, so the whole range is valid).
        getPriceFromId(lower, binStep);
        getPriceFromId(upper, binStep);
    }

    /// @dev Amounts a deposit of `shares` into bin `b` costs (rounded up, against the depositor).
    function _depositAmounts(Bin storage bin, int24 b, uint128 shares, int24 activeId, uint16 binStep)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 total = bin.totalShares;
        if (total != 0) {
            amount0 = FullMathLib.mulDivRoundingUp(shares, bin.reserve0, total);
            amount1 = FullMathLib.mulDivRoundingUp(shares, bin.reserve1, total);
        } else {
            uint256 price = getPriceFromId(b, binStep);
            if (b > activeId) {
                amount0 = FullMathLib.mulDivRoundingUp(shares, SCALE, price);
            } else if (b < activeId) {
                amount1 = shares;
            } else {
                uint256 half = uint256(shares) / 2;
                amount1 = uint256(shares) - half;
                amount0 = FullMathLib.mulDivRoundingUp(half, SCALE, price);
            }
        }
    }

    function _addToBin(BinPoolState storage pool, Bin storage bin, int24 b, uint128 shares, ModifyVars memory v)
        internal
    {
        (uint256 a0, uint256 a1) = _depositAmounts(bin, b, shares, v.activeId, v.binStep);
        if (bin.totalShares == 0) pool.tree.add(TreeBitmapLib.toKey(b));
        bin.reserve0 = SafeCastLib.toUint128(uint256(bin.reserve0) + a0);
        bin.reserve1 = SafeCastLib.toUint128(uint256(bin.reserve1) + a1);
        bin.totalShares = SafeCastLib.toUint128(uint256(bin.totalShares) + shares);
        v.amount0 += a0;
        v.amount1 += a1;
    }

    function _removeFromBin(BinPoolState storage pool, Bin storage bin, int24 b, uint128 shares, ModifyVars memory v)
        internal
    {
        uint256 total = bin.totalShares;
        if (total < shares) revert PoolErrors.LiquidityOverflow();
        uint256 a0 = FullMathLib.mulDiv(shares, bin.reserve0, total);
        uint256 a1 = FullMathLib.mulDiv(shares, bin.reserve1, total);
        bin.reserve0 -= uint128(a0);
        bin.reserve1 -= uint128(a1);
        bin.totalShares = uint128(total - shares);
        if (total == shares) pool.tree.remove(TreeBitmapLib.toKey(b));
        v.amount0 += a0;
        v.amount1 += a1;
    }

    // ------------------------------------------------------------------ swap

    struct SwapState {
        int24 activeId;
        uint256 remaining;
        uint256 calculated;
        uint256 protocolFee;
    }

    struct SwapCtx {
        bool zeroForOne;
        bool exactInput;
        uint24 fee;
        uint24 protocolFee;
        uint16 binStep;
        uint256 limitPriceX128;
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, uint24 fee, uint24 protocolFee)
        external
        override
        onlyPoolManager
        returns (BalanceDelta swapDelta, uint256 protocolFeeAmount)
    {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (params.amountSpecified == 0) revert PoolErrors.ZeroSwapAmount();
        if (fee >= MAX_FEE_PIPS) revert PoolErrors.InvalidFee(fee);

        SwapCtx memory ctx = SwapCtx({
            zeroForOne: params.zeroForOne,
            exactInput: params.amountSpecified > 0,
            fee: fee,
            protocolFee: protocolFee,
            binStep: pool.binStep,
            limitPriceX128: _resolveLimit(pool, params)
        });
        SwapState memory s = SwapState({
            activeId: pool.activeId,
            remaining: params.amountSpecified > 0 ? uint256(params.amountSpecified) : uint256(-params.amountSpecified),
            calculated: 0,
            protocolFee: 0
        });

        // The starting bin is always on the permitted side of the limit (`_resolveLimit` is strict). The active id
        // only moves to a bin that is itself within the limit, so slot0 never reports a price beyond the limit.
        uint256 price = getPriceFromId(s.activeId, ctx.binStep);
        while (true) {
            _swapInBin(pool.bins[s.activeId], s, ctx, price);
            if (s.remaining == 0) break;
            (bool found, uint24 nextKey) = ctx.zeroForOne
                ? pool.tree.nextBelow(TreeBitmapLib.toKey(s.activeId))
                : pool.tree.nextAbove(TreeBitmapLib.toKey(s.activeId));
            if (!found) break;
            int24 nextId = TreeBitmapLib.fromKey(nextKey);
            uint256 nextPrice = getPriceFromId(nextId, ctx.binStep);
            if (ctx.zeroForOne ? nextPrice < ctx.limitPriceX128 : nextPrice > ctx.limitPriceX128) break;
            s.activeId = nextId;
            price = nextPrice;
        }

        pool.activeId = s.activeId;
        pool.slot0 = pool.slot0.setSqrtPriceX96(_sqrtPriceOf(getPriceFromId(s.activeId, ctx.binStep))).setTick(
            s.activeId
        );
        protocolFeeAmount = s.protocolFee;
        swapDelta = _swapDelta(params, s);
    }

    /// @dev 0 = no limit; otherwise the limit must be strictly on the swap side of the current bin price.
    function _resolveLimit(BinPoolState storage pool, IPoolManager.SwapParams memory params)
        internal
        view
        returns (uint256)
    {
        if (params.sqrtPriceLimitX96 == 0) return params.zeroForOne ? 0 : type(uint256).max;
        uint160 current = pool.slot0.sqrtPriceX96();
        if (params.zeroForOne ? params.sqrtPriceLimitX96 >= current : params.sqrtPriceLimitX96 <= current) {
            revert PoolErrors.PriceLimitAlreadyExceeded(current, params.sqrtPriceLimitX96);
        }
        return BinMathLib.getPriceX128FromSqrtPriceX96(params.sqrtPriceLimitX96);
    }

    /// @dev Trades inside one bin at its constant price, up to the bin's output reserve.
    function _swapInBin(Bin storage bin, SwapState memory s, SwapCtx memory ctx, uint256 price) internal {
        uint256 maxOut = ctx.zeroForOne ? bin.reserve1 : bin.reserve0;
        if (maxOut == 0) return;

        uint256 amountInNoFee;
        uint256 feeAmount;
        uint256 amountOut;
        if (ctx.exactInput) {
            // Input (no fee) that would buy the whole output reserve.
            uint256 fullIn = _inForOut(maxOut, price, ctx.zeroForOne);
            uint256 fullFee = FullMathLib.mulDivRoundingUp(fullIn, ctx.fee, MAX_FEE_PIPS - ctx.fee);
            if (s.remaining >= fullIn + fullFee) {
                amountInNoFee = fullIn;
                feeAmount = fullFee;
                amountOut = maxOut;
            } else {
                feeAmount = FullMathLib.mulDivRoundingUp(s.remaining, ctx.fee, MAX_FEE_PIPS);
                amountInNoFee = s.remaining - feeAmount;
                amountOut = _outForIn(amountInNoFee, price, ctx.zeroForOne);
                if (amountOut > maxOut) amountOut = maxOut;
            }
            s.remaining -= amountInNoFee + feeAmount;
            s.calculated += amountOut;
        } else {
            amountOut = s.remaining < maxOut ? s.remaining : maxOut;
            amountInNoFee = _inForOut(amountOut, price, ctx.zeroForOne);
            feeAmount = FullMathLib.mulDivRoundingUp(amountInNoFee, ctx.fee, MAX_FEE_PIPS - ctx.fee);
            s.remaining -= amountOut;
            s.calculated += amountInNoFee + feeAmount;
        }

        if (ctx.zeroForOne) {
            bin.reserve0 = SafeCastLib.toUint128(uint256(bin.reserve0) + amountInNoFee);
            bin.reserve1 -= uint128(amountOut);
        } else {
            bin.reserve1 = SafeCastLib.toUint128(uint256(bin.reserve1) + amountInNoFee);
            bin.reserve0 -= uint128(amountOut);
        }

        if (feeAmount > 0) {
            (uint256 lpFee, uint256 protocolTake) = ProtocolFeeLib.splitFee(feeAmount, ctx.protocolFee);
            s.protocolFee += protocolTake;
            if (lpFee > 0) {
                uint256 g = FullMathLib.mulDiv(lpFee, Q128, bin.totalShares);
                if (ctx.zeroForOne) bin.feeGrowth0X128 += g;
                else bin.feeGrowth1X128 += g;
            }
        }
    }

    /// @dev Input needed (rounded up) to receive `amountOut` at `price` (token1 per token0, Q128).
    function _inForOut(uint256 amountOut, uint256 price, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne
            ? FullMathLib.mulDivRoundingUp(amountOut, SCALE, price)
            : FullMathLib.mulDivRoundingUp(amountOut, price, SCALE);
    }

    /// @dev Output (rounded down) for `amountIn` at `price`.
    function _outForIn(uint256 amountIn, uint256 price, bool zeroForOne) internal pure returns (uint256) {
        return zeroForOne ? FullMathLib.mulDiv(amountIn, price, SCALE) : FullMathLib.mulDiv(amountIn, SCALE, price);
    }

    function _swapDelta(IPoolManager.SwapParams memory params, SwapState memory s) internal pure returns (BalanceDelta) {
        bool exactInput = params.amountSpecified > 0;
        int256 specifiedUsed = exactInput
            ? params.amountSpecified - SafeCastLib.toInt256(s.remaining)
            : params.amountSpecified + SafeCastLib.toInt256(s.remaining);
        int128 specified = SafeCastLib.toInt128(specifiedUsed);
        int128 calculated = SafeCastLib.toInt128(SafeCastLib.toInt256(s.calculated));
        if (exactInput) calculated = -calculated;
        if (params.zeroForOne == exactInput) return toBalanceDelta(specified, calculated);
        return toBalanceDelta(calculated, specified);
    }

    // ------------------------------------------------------------------ donate / views

    /// @inheritdoc ICurveEngine
    /// @dev Donations accrue to the shares of the ACTIVE bin.
    function donate(PoolKey memory key, uint256 amount0, uint256 amount1) external override onlyPoolManager {
        PoolId id = key.toId();
        BinPoolState storage pool = pools[id];
        if (!pool.slot0.isInitialized()) revert PoolErrors.PoolNotInitialized(id);
        if (amount0 == 0 && amount1 == 0) return;
        Bin storage activeBin = pool.bins[pool.activeId];
        uint128 shares = activeBin.totalShares;
        if (shares == 0) revert PoolErrors.NoLiquidityToDonate();
        if (amount0 > 0) activeBin.feeGrowth0X128 += FullMathLib.mulDiv(amount0, Q128, shares);
        if (amount1 > 0) activeBin.feeGrowth1X128 += FullMathLib.mulDiv(amount1, Q128, shares);
    }

    function getSlot0(PoolId id) external view override returns (Slot0) {
        return pools[id].slot0;
    }

    /// @notice Shares in the active bin (the liquidity a donation / fee redistribution would credit).
    function getLiquidity(PoolId id) external view override returns (uint128) {
        return pools[id].bins[pools[id].activeId].totalShares;
    }

    function getActiveBinId(PoolId id) external view returns (int24) {
        return pools[id].activeId;
    }

    function getBinStep(PoolId id) external view returns (uint16) {
        return pools[id].binStep;
    }

    function getBinReserves(PoolId id, int24 binId) external view returns (uint128 reserve0, uint128 reserve1) {
        Bin storage bin = pools[id].bins[binId];
        return (bin.reserve0, bin.reserve1);
    }

    function getBin(PoolId id, int24 binId)
        external
        view
        returns (uint128 reserve0, uint128 reserve1, uint128 totalShares, uint256 feeGrowth0X128, uint256 feeGrowth1X128)
    {
        Bin storage bin = pools[id].bins[binId];
        return (bin.reserve0, bin.reserve1, bin.totalShares, bin.feeGrowth0X128, bin.feeGrowth1X128);
    }

    /// @notice Next bin holding liquidity strictly below (`below = true`) or above `binId`.
    function getNextNonEmptyBin(PoolId id, int24 binId, bool below) external view returns (bool found, int24 next) {
        (bool f, uint24 k) = below
            ? pools[id].tree.nextBelow(TreeBitmapLib.toKey(binId))
            : pools[id].tree.nextAbove(TreeBitmapLib.toKey(binId));
        return (f, f ? TreeBitmapLib.fromKey(k) : int24(0));
    }

    /// @notice Token amounts adding `shares` to every bin of [binLower, binUpper] would cost right now.
    function quoteAddLiquidity(PoolId id, int24 binLower, int24 binUpper, uint128 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        BinPoolState storage pool = pools[id];
        _checkRange(binLower, binUpper, pool.binStep);
        for (int24 b = binLower; b <= binUpper; b++) {
            (uint256 a0, uint256 a1) = _depositAmounts(pool.bins[b], b, shares, pool.activeId, pool.binStep);
            amount0 += a0;
            amount1 += a1;
        }
    }

    /// @notice Token amounts burning `shares` from every bin of [binLower, binUpper] would return right now.
    function quoteRemoveLiquidity(PoolId id, int24 binLower, int24 binUpper, uint128 shares)
        external
        view
        returns (uint256 amount0, uint256 amount1)
    {
        BinPoolState storage pool = pools[id];
        _checkRange(binLower, binUpper, pool.binStep);
        for (int24 b = binLower; b <= binUpper; b++) {
            Bin storage bin = pool.bins[b];
            if (bin.totalShares == 0) continue;
            amount0 += FullMathLib.mulDiv(shares, bin.reserve0, bin.totalShares);
            amount1 += FullMathLib.mulDiv(shares, bin.reserve1, bin.totalShares);
        }
    }

    function getPosition(PoolId id, address owner, int24 binLower, int24 binUpper, bytes32 salt)
        external
        view
        returns (Position.Info memory)
    {
        return pools[id].positions[Position.getKey(owner, binLower, binUpper, salt)];
    }
}
