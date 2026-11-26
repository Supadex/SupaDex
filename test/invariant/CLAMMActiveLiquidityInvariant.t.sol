// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
contract CLAMMLiquidityHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    int24 internal constant A_LO = -120;
    int24 internal constant A_HI = 120;
    int24 internal constant B_LO = 120;
    int24 internal constant B_HI = 240;

    SupaVault public vault;
    SupaPoolManager public manager;
    PoolKey public key;
    uint128 public liqA;
    uint128 public liqB;

    constructor(SupaVault _vault, SupaPoolManager _manager, PoolKey memory _key) {
        vault = _vault;
        manager = _manager;
        key = _key;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint256 amount, bool zeroForOne) = abi.decode(data, (uint8, uint256, bool));
        if (action == 0 || action == 1) {
            int24 lo = action == 0 ? A_LO : B_LO;
            int24 hi = action == 0 ? A_HI : B_HI;
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: int256(amount), salt: bytes32(uint256(action))
                }),
                ""
            );
            // The vault is moved by principal - fees. Settle that net, or accrued fees are left open.
            _settle(principal.sub(fees));
            if (action == 0) liqA += uint128(amount);
            else liqB += uint128(amount);
        } else if (action == 2 || action == 3) {
            uint128 have = action == 2 ? liqA : liqB;
            if (amount > have) amount = have;
            if (amount == 0) return "";
            int24 lo = action == 2 ? A_LO : B_LO;
            int24 hi = action == 2 ? A_HI : B_HI;
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lo, tickUpper: hi, liquidityDelta: -int256(amount), salt: bytes32(uint256(action - 2))
                }),
                ""
            );
            _settle(principal.sub(fees));
            if (action == 2) liqA -= uint128(amount);
            else liqB -= uint128(amount);
        } else {
            int256 specified = zeroForOne ? int256(amount) : int256(amount);
            BalanceDelta delta = manager.swap(
                key,
                IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: specified, sqrtPriceLimitX96: 0}),
                ""
            );
            _settle(delta);
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

    /// Includes 1-wei swaps (T-2).
    function swap(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 1, 100 ether);
        _fund(amount);
        vault.unlock(abi.encode(uint8(4), amount, zeroForOne));
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
        targetContract(address(handler));
    }

    function invariant_activeLiquidityMatchesPositions() public view {
        int24 tick = engine.getSlot0(key.toId()).tick();
        uint128 expected;
        if (tick >= -120 && tick < 120) expected += handler.liqA();
        if (tick >= 120 && tick < 240) expected += handler.liqB();
        assertEq(engine.getLiquidity(key.toId()), expected, "pool.liquidity == sum of in-range positions");
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
}
