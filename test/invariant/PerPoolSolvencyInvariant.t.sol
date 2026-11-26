// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract MockPerPoolToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev T-4 (M-01): ghost-tracks the net inflow of every pool, per currency,
/// from the exact deltas the PoolManager settles, and the test asserts the
/// ghost equals the manager's on-chain `poolReserves` pot — and never goes
/// negative — for every pool. A cross-pool drain (one pool paying out against
/// another pool's pot) shows up here as ghost != pot, even while the vault
/// as a whole still looks solvent.
contract PerPoolSolvencyHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockPerPoolToken public tokenA;
    MockPerPoolToken public tokenB;

    /// Ghost net inflow per pool per currency: positive legs (user pays in)
    /// add, negative legs (pool pays out) subtract. Must equal
    /// manager.poolReserves(pool, currency) at all times, and never be < 0.
    mapping(bytes32 => mapping(address => int256)) public ghostNet;
    /// Params-amount of liquidity added per pool (BIN spreads it per bin, so
    /// removals must use the same params-amount scale).
    mapping(uint256 => uint256) public added;

    constructor(
        SupaVault _vault,
        SupaPoolManager _manager,
        PoolKey memory _clammKey,
        PoolKey memory _binKey,
        PoolKey memory _stableKey,
        MockPerPoolToken _tokenA,
        MockPerPoolToken _tokenB
    ) {
        vault = _vault;
        manager = _manager;
        clammKey = _clammKey;
        binKey = _binKey;
        stableKey = _stableKey;
        tokenA = _tokenA;
        tokenB = _tokenB;
    }

    function _pool(uint256 poolSeed) internal view returns (PoolKey memory) {
        uint256 p = poolSeed % 3;
        if (p == 0) return clammKey;
        if (p == 1) return binKey;
        return stableKey;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint8 poolIdx, bool zeroForOne, uint256 amount) = abi.decode(data, (uint8, uint8, bool, uint256));
        uint256 p = poolIdx % 3;
        PoolKey memory k = _pool(p);

        if (action == 0) {
            // Add liquidity.
            IPoolManager.ModifyLiquidityParams memory params = SecurityTestSetup.liquidityParams(k, amount, true);
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(k, params, "");
            _settleAndTrack(k, principal.sub(fees));
            added[p] += amount;
        } else if (action == 1) {
            // Remove liquidity (amount is a params-amount, not a pct).
            if (amount > added[p]) amount = added[p];
            if (amount == 0) return "";
            IPoolManager.ModifyLiquidityParams memory params = SecurityTestSetup.liquidityParams(k, amount, false);
            (BalanceDelta principal, BalanceDelta fees) = manager.modifyLiquidity(k, params, "");
            _settleAndTrack(k, principal.sub(fees));
            added[p] -= amount;
        } else if (action == 2) {
            // Swap (1-wei dust included: bound in swap()).
            BalanceDelta delta = manager.swap(
                k,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: int256(amount), sqrtPriceLimitX96: 0
                }),
                ""
            );
            _settleAndTrack(k, delta);
        } else if (action == 3) {
            // Donate: the pot grows by the donated amounts directly.
            BalanceDelta delta = manager.donate(k, amount, amount, "");
            _settleAndTrack(k, delta);
        }
        return "";
    }

    function _settleAndTrack(PoolKey memory k, BalanceDelta delta) internal {
        bytes32 id = PoolId.unwrap(k.toId());
        ghostNet[id][Currency.unwrap(k.currency0)] += int256(delta.amount0());
        ghostNet[id][Currency.unwrap(k.currency1)] += int256(delta.amount1());
        _settle(k, delta);
    }

    function _settle(PoolKey memory k, BalanceDelta delta) internal {
        _leg(k.currency0, delta.amount0());
        _leg(k.currency1, delta.amount1());
    }

    function _leg(Currency currency, int128 amount) internal {
        if (amount > 0) {
            vault.sync(currency);
            MockPerPoolToken(Currency.unwrap(currency)).transfer(address(vault), uint256(uint128(amount)));
            vault.settle(currency);
        } else if (amount < 0) {
            vault.take(currency, address(this), uint256(uint128(-amount)));
        }
    }

    function _mintFor(PoolKey memory k, bool zeroForOne, uint256 amount) internal {
        if (zeroForOne) {
            MockPerPoolToken(Currency.unwrap(k.currency0)).mint(address(this), amount);
        } else {
            MockPerPoolToken(Currency.unwrap(k.currency1)).mint(address(this), amount);
        }
    }

    function addLiquidity(uint256 poolSeed, uint256 amount) external {
        uint256 p = poolSeed % 3;
        PoolKey memory k = _pool(p);
        amount = bound(amount, 1_000, 10_000 ether);
        MockPerPoolToken(Currency.unwrap(k.currency0)).mint(address(this), amount * 4);
        MockPerPoolToken(Currency.unwrap(k.currency1)).mint(address(this), amount * 4);
        vault.unlock(abi.encode(uint8(0), uint8(p), false, amount));
    }

    function removeLiquidity(uint256 poolSeed, uint256 pct) external {
        uint256 p = poolSeed % 3;
        if (added[p] == 0) return;
        uint256 amount = added[p] * bound(pct, 1, 100) / 100;
        if (amount == 0) return;
        vault.unlock(abi.encode(uint8(1), uint8(p), false, amount));
    }

    /// T-2 aligned: swap amounts start at 1 wei.
    function swap(uint256 poolSeed, bool zeroForOne, uint256 amount) external {
        uint256 p = poolSeed % 3;
        PoolKey memory k = _pool(p);
        amount = bound(amount, 1, 5_000 ether);
        _mintFor(k, zeroForOne, amount * 2);
        vault.unlock(abi.encode(uint8(2), uint8(p), zeroForOne, amount));
    }

    function dustSwap(uint256 poolSeed, bool zeroForOne) external {
        uint256 p = poolSeed % 3;
        PoolKey memory k = _pool(p);
        _mintFor(k, zeroForOne, 2);
        vault.unlock(abi.encode(uint8(2), uint8(p), zeroForOne, uint256(1)));
    }

    function donate(uint256 poolSeed, uint256 amount) external {
        uint256 p = poolSeed % 3;
        PoolKey memory k = _pool(p);
        amount = bound(amount, 1, 1_000 ether);
        MockPerPoolToken(Currency.unwrap(k.currency0)).mint(address(this), amount * 2);
        MockPerPoolToken(Currency.unwrap(k.currency1)).mint(address(this), amount * 2);
        vault.unlock(abi.encode(uint8(3), uint8(p), false, amount));
    }
}

contract PerPoolSolvencyInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    PerPoolSolvencyHandler public handler;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockPerPoolToken public tokenA;
    MockPerPoolToken public tokenB;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEnginesBinEnabled(vault);
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));

        MockPerPoolToken[2] memory rawTokens;
        rawTokens[0] = new MockPerPoolToken("Token A", "TKNA");
        rawTokens[1] = new MockPerPoolToken("Token B", "TKNB");
        if (address(rawTokens[0]) > address(rawTokens[1])) {
            (rawTokens[0], rawTokens[1]) = (rawTokens[1], rawTokens[0]);
        }
        tokenA = rawTokens[0];
        tokenB = rawTokens[1];

        Currency cA = Currency.wrap(address(tokenA));
        Currency cB = Currency.wrap(address(tokenB));

        clammKey = PoolKey({
            currency0: cA, currency1: cB, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
        });
        binKey = PoolKey({
            currency0: cA, currency1: cB, fee: 2000, tickSpacing: 10, plugin: address(0), curveType: CurveType.BIN_AMM
        });
        stableKey = PoolKey({
            currency0: cA, currency1: cB, fee: 500, tickSpacing: 1, plugin: address(0), curveType: CurveType.STABLE_AMM
        });

        manager.initialize(clammKey, 1 << 96, "");
        manager.initialize(binKey, 1 << 96, "");
        manager.initializeWithParams(stableKey, 1 << 96, abi.encode(uint256(100)), "");

        handler = new PerPoolSolvencyHandler(vault, manager, clammKey, binKey, stableKey, tokenA, tokenB);

        handler.addLiquidity(0, 10_000 ether);
        handler.addLiquidity(1, 10_000 ether);
        handler.addLiquidity(2, 10_000 ether);

        targetContract(address(handler));
    }

    function _pools() internal view returns (PoolKey[3] memory ks) {
        ks[0] = clammKey;
        ks[1] = binKey;
        ks[2] = stableKey;
    }

    /// @notice T-4: for EVERY pool and EVERY currency, the ghost-tracked net
    /// inflow is non-negative and exactly equals the manager's on-chain
    /// poolReserves pot. Any engine accounting bug that lets a pool pay out
    /// more than it took in breaks this, even if the vault as a whole is solvent.
    function invariant_perPoolGhostMatchesPot() public view {
        PoolKey[3] memory ks = _pools();
        for (uint256 i; i < 3; i++) {
            bytes32 id = PoolId.unwrap(ks[i].toId());
            _assertPoolPot(ks[i], id, ks[i].currency0);
            _assertPoolPot(ks[i], id, ks[i].currency1);
        }
    }

    function _assertPoolPot(PoolKey memory k, bytes32 id, Currency currency) internal view {
        int256 ghost = handler.ghostNet(id, Currency.unwrap(currency));
        assertGe(ghost, 0, "per-pool ghost net inflow went negative");
        assertEq(uint256(ghost), manager.poolReserves(k.toId(), currency), "ghost != on-chain pool pot");
    }

    /// @notice T-4: the per-pool pots plus protocol fees plus outstanding
    /// claims never exceed the vault's reserves for that currency, and
    /// reserves never exceed the physical balance.
    function invariant_perPoolPotsCoveredByVault() public view {
        _assertCurrencyCovered(clammKey.currency0);
        _assertCurrencyCovered(clammKey.currency1);
    }

    function _assertCurrencyCovered(Currency currency) internal view {
        PoolKey[3] memory ks = _pools();
        uint256 pots;
        for (uint256 i; i < 3; i++) {
            pots += manager.poolReserves(ks[i].toId(), currency);
        }
        uint256 owed = pots + manager.protocolFeesAccrued(currency) + vault.claimSupplyOf(currency);
        assertLe(owed, vault.reservesOf(currency), "pool pots + fees + claims exceed reserves");
        assertLe(vault.reservesOf(currency), currency.balanceOf(address(vault)), "reserves exceed balance");
    }
}
