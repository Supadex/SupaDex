// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract LiqToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// T-2 / T-3: dust-sized swaps plus `pool.liquidity == sum of in-range positions`.
/// Ghost-tracked positions in three adjacent ranges (A [-120,120), B [120,240),
/// C [240,360)), each with its own salt, so the liquidity-sum invariant is
/// checked against the engine's per-position state as well as the handler ghost.
contract CLAMMLiquidityHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    int24 internal constant A_LO = -120;
    int24 internal constant A_HI = 120;
    int24 internal constant B_LO = 120;
    int24 internal constant B_HI = 240;
    int24 internal constant C_LO = 240;
    int24 internal constant C_HI = 360;

    SupaVault public vault;
    SupaPoolManager public manager;
    PoolKey public key;
    uint128 public liqA;
    uint128 public liqB;
    uint128 public liqC;
    uint256 public dustSwapsExecuted;
    uint256 public tickTargetedSwapsExecuted;

    constructor(SupaVault _vault, SupaPoolManager _manager, PoolKey memory _key) {
        vault = _vault;
        manager = _manager;
        key = _key;
    }

    function _range(uint8 action) internal pure returns (int24 lo, int24 hi, bytes32 salt, uint8 slot) {
        if (action == 0 || action == 2) return (A_LO, A_HI, bytes32(uint256(0)), 0);
        if (action == 1 || action == 3) return (B_LO, B_HI, bytes32(uint256(1)), 1);
        return (C_LO, C_HI, bytes32(uint256(2)), 2);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint256 amount, bool zeroForOne) = abi.decode(data, (uint8, uint256, bool));
        if (action == 0 || action == 1 || action == 5) {
            (int24 lo, int24 hi, bytes32 salt, uint8 slot) = _range(action);
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: int256(amount), salt: salt
                }),
                ""
            );
            // The vault is moved by principal - fees. Settle that net, or accrued fees are left open.
            _settle(principal.sub(fees));
            if (slot == 0) liqA += uint128(amount);
            else if (slot == 1) liqB += uint128(amount);
            else liqC += uint128(amount);
        } else if (action == 2 || action == 3 || action == 6) {
            (int24 lo, int24 hi, bytes32 salt, uint8 slot) = _range(action);
            uint128 have = slot == 0 ? liqA : slot == 1 ? liqB : liqC;
            if (amount > have) amount = have;
            if (amount == 0) return "";
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: -int256(amount), salt: salt
                }),
                ""
            );
            _settle(principal.sub(fees));
            if (slot == 0) liqA -= uint128(amount);
            else if (slot == 1) liqB -= uint128(amount);
            else liqC -= uint128(amount);
        } else if (action == 7) {
            // T-2: swap TO exactly an initialized tick, then immediately make a
            // 1-wei dust swap in the same direction. This is the C-02 trigger: a
            // zero-movement step right after a tick cross.
            int24 target = zeroForOne ? A_LO : B_LO;
            uint160 limit = TickMathLib.getSqrtRatioAtTick(target);
            BalanceDelta first = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: int256(100 ether), sqrtPriceLimitX96: limit
                }),
                ""
            );
            _settle(first);
            tickTargetedSwapsExecuted++;
            BalanceDelta dust = manager.swap(
                key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: 1, sqrtPriceLimitX96: 0}), ""
            );
            _settle(dust);
            dustSwapsExecuted++;
        } else {
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: int256(amount), sqrtPriceLimitX96: 0
                }),
                ""
            );
            _settle(delta);
            if (amount == 1) dustSwapsExecuted++;
        }
        return "";
    }

    function addA(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        _fund(amount);
        vault.unlock(abi.encode(uint8(0), amount, false));
    }

    function addB(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        _fund(amount);
        vault.unlock(abi.encode(uint8(1), amount, false));
    }

    function addC(uint256 amount) external {
        amount = bound(amount, 1, 1_000 ether);
        _fund(amount);
        vault.unlock(abi.encode(uint8(5), amount, false));
    }

    function removeA(uint256 amount) external {
        if (liqA == 0) return;
        amount = bound(amount, 1, liqA);
        vault.unlock(abi.encode(uint8(2), amount, false));
    }

    function removeB(uint256 amount) external {
        if (liqB == 0) return;
        amount = bound(amount, 1, liqB);
        vault.unlock(abi.encode(uint8(3), amount, false));
    }

    function removeC(uint256 amount) external {
        if (liqC == 0) return;
        amount = bound(amount, 1, liqC);
        vault.unlock(abi.encode(uint8(6), amount, false));
    }

    /// Includes 1-wei swaps (T-2).
    function swap(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        _fund(amount);
        vault.unlock(abi.encode(uint8(4), amount, zeroForOne));
    }

    /// A single 1-wei dust swap (T-2).
    function dustSwap(bool zeroForOne) external {
        _fund(1);
        vault.unlock(abi.encode(uint8(4), uint256(1), zeroForOne));
    }

    /// T-2: swap TO exactly an initialized tick (-120 going down, +120 going
    /// up) and then immediately execute a 1-wei dust swap in the same
    /// direction, in a single unlock. No-ops when the price is already at or
    /// beyond the target tick (the limit would be on the wrong side).
    function swapToTickThenDust(bool zeroForOne) external {
        int24 tick = manager.getSlot0(key.toId()).tick();
        if (zeroForOne && tick <= A_LO) return;
        if (!zeroForOne && tick >= B_LO) return;
        _fund(100 ether);
        vault.unlock(abi.encode(uint8(7), uint256(0), zeroForOne));
    }

    function _fund(uint256 amount) internal {
        LiqToken(Currency.unwrap(key.currency0)).mint(address(this), amount * 4 + 1);
        LiqToken(Currency.unwrap(key.currency1)).mint(address(this), amount * 4 + 1);
    }

    function _settle(BalanceDelta delta) internal {
        _leg(key.currency0, delta.amount0());
        _leg(key.currency1, delta.amount1());
    }

    function _leg(Currency currency, int128 amount) internal {
        if (amount > 0) {
            vault.sync(currency);
            LiqToken(Currency.unwrap(currency)).transfer(address(vault), uint256(uint128(amount)));
            vault.settle(currency);
        } else if (amount < 0) {
            vault.take(currency, address(this), uint256(uint128(-amount)));
        }
    }
}

contract CLAMMActiveLiquidityInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    CLAMMEngine internal engine;
    CLAMMLiquidityHandler internal handler;
    PoolKey internal key;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        engine = CLAMMEngine(address(manager.clammEngine()));
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));

        LiqToken a = new LiqToken();
        LiqToken b = new LiqToken();
        if (address(a) > address(b)) (a, b) = (b, a);
        key = PoolKey({
            currency0: Currency.wrap(address(a)),
            currency1: Currency.wrap(address(b)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(key, TickMathLib.getSqrtRatioAtTick(0), "");
        handler = new CLAMMLiquidityHandler(vault, manager, key);
        handler.addA(1_000_000);
        handler.addB(1_000_000);
        handler.addC(1_000_000);
        targetContract(address(handler));
    }

    function invariant_activeLiquidityMatchesPositions() public view {
        int24 tick = engine.getSlot0(key.toId()).tick();
        uint128 expected;
        if (tick >= -120 && tick < 120) expected += handler.liqA();
        if (tick >= 120 && tick < 240) expected += handler.liqB();
        if (tick >= 240 && tick < 360) expected += handler.liqC();
        assertEq(engine.getLiquidity(key.toId()), expected, "pool.liquidity == sum of in-range positions");
    }

    /// T-3: the engine's own per-position state must match the ghost-tracked
    /// handler balances for every range, not just the aggregate sum. A
    /// re-crossed tick (C-02) would double-apply liquidityNet to the pool
    /// without changing any position, so this catches it from a second angle.
    function invariant_positionLiquidityMatchesGhost() public view {
        PoolId id = key.toId();
        assertEq(
            engine.getPosition(id, address(handler), -120, 120, bytes32(uint256(0))).liquidity,
            handler.liqA(),
            "engine position A drifted from ghost"
        );
        assertEq(
            engine.getPosition(id, address(handler), 120, 240, bytes32(uint256(1))).liquidity,
            handler.liqB(),
            "engine position B drifted from ghost"
        );
        assertEq(
            engine.getPosition(id, address(handler), 240, 360, bytes32(uint256(2))).liquidity,
            handler.liqC(),
            "engine position C drifted from ghost"
        );
    }

    function invariant_tickAgreesWithPrice() public view {
        Slot0 slot0 = engine.getSlot0(key.toId());
        uint160 price = slot0.sqrtPriceX96();
        int24 fromPrice = TickMathLib.getTickAtSqrtRatio(price);
        int24 stored = slot0.tick();
        // After a downward cross the price sits on the crossed tick and the stored tick is one below it.
        assertTrue(stored == fromPrice || stored + 1 == fromPrice, "tick drifted from price");
        if (stored + 1 == fromPrice) {
            assertEq(price, TickMathLib.getSqrtRatioAtTick(fromPrice));
        }
    }

    function afterInvariant() external view {
        console2.log("dust swaps executed:", handler.dustSwapsExecuted());
        console2.log("tick-targeted swaps executed:", handler.tickTargetedSwapsExecuted());
    }
}
