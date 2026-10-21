// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {IPluginEvents} from "../../contract/events/IPluginEvents.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {Slot0Library} from "../../contract/types/Slot0.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {IPluginWhitelist} from "../../contract/interfaces/IPluginWhitelist.sol";
import {ISupaRoles} from "../../contract/interfaces/ISupaRoles.sol";
import {SupaRoles} from "../../contract/governance/SupaRoles.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

contract MockPluginToken {
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
        require(balanceOf[msg.sender] >= amount, "MockPluginToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PluginIntegrationHarness is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    enum Action {
        ADD_LIQUIDITY,
        REMOVE_LIQUIDITY,
        SWAP
    }

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function execute(bytes calldata data) external returns (bytes memory) {
        return vault.unlock(data);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Action action, PoolKey memory key, uint256 val) = abi.decode(data, (Action, PoolKey, uint256));

        if (action == Action.ADD_LIQUIDITY) {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: int256(val), salt: bytes32(0)
            });

            (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

            if (delta.amount0() > 0) {
                vault.sync(key.currency0);
                MockPluginToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() > 0) {
                vault.sync(key.currency1);
                MockPluginToken(Currency.unwrap(key.currency1)).transfer(address(vault), uint128(delta.amount1()));
                vault.settle(key.currency1);
            }
        } else if (action == Action.REMOVE_LIQUIDITY) {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -int256(val), salt: bytes32(0)
            });

            // PoolManager accounts principal + feesAccrued into vault deltas; settle via live deltas.
            manager.modifyLiquidity(key, params, "");
            _settleCurrency(key.currency0);
            _settleCurrency(key.currency1);
        } else if (action == Action.SWAP) {
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: int256(val), sqrtPriceLimitX96: TickMathLib.MIN_SQRT_RATIO + 1
            });

            BalanceDelta delta = manager.swap(key, swapParams, "");

            if (delta.amount0() > 0) {
                vault.sync(key.currency0);
                MockPluginToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                vault.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        }

        return abi.encode(true);
    }

    function _settleCurrency(Currency currency) internal {
        int256 d = vault.getCurrencyDelta(address(this), currency);
        if (d > 0) {
            vault.take(currency, address(this), uint256(d));
        } else if (d < 0) {
            vault.sync(currency);
            MockPluginToken(Currency.unwrap(currency)).transfer(address(vault), uint256(-d));
            vault.settle(currency);
        }
    }
}

contract NativePluginsIntegrationTest is Test, IPluginEvents {
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    CLAMMEngine public clamm;
    BinAMMEngine public binAmm;
    StableAMMEngine public stableAmm;

    VolatilityTWAPOracle public oracle;
    LVRShieldPlugin public lvrPlugin;
    AntiJITVestingPlugin public jitPlugin;

    PluginIntegrationHarness public harness;
    MockPluginToken public tokenA;
    MockPluginToken public tokenB;
    Currency public currency0;
    Currency public currency1;

    PoolKey public lvrPoolKey;
    PoolKey public jitPoolKey;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        clamm = CLAMMEngine(address(manager.clammEngine()));
        binAmm = BinAMMEngine(address(manager.binEngine()));
        stableAmm = StableAMMEngine(address(manager.stableEngine()));
        vault.setPoolManager(address(manager), true);
        lvrPlugin = new LVRShieldPlugin(manager);
        oracle = VolatilityTWAPOracle(address(lvrPlugin.oracle()));
        jitPlugin = new AntiJITVestingPlugin(manager, 3); // 3 blocks residency

        address[] memory plugins = new address[](2);
        plugins[0] = address(lvrPlugin);
        plugins[1] = address(jitPlugin);
        PluginWhitelist wl = new PluginWhitelist(address(this), plugins);
        wl.setPluginCanReturnDelta(address(jitPlugin), true);
        manager.setPluginWhitelist(IPluginWhitelist(address(wl)));

        harness = new PluginIntegrationHarness(vault, manager);

        tokenA = new MockPluginToken("Token A", "TKNA");
        tokenB = new MockPluginToken("Token B", "TKNB");

        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        lvrPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(lvrPlugin),
            curveType: CurveType.CLAMM
        });

        jitPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(jitPlugin),
            curveType: CurveType.CLAMM
        });

        MockPluginToken(Currency.unwrap(currency0)).mint(address(harness), 100_000_000 ether);
        MockPluginToken(Currency.unwrap(currency1)).mint(address(harness), 100_000_000 ether);
    }

    function test_endToEndLVRShieldDynamicSwap() public {
        // Wire roles so operator can calibrate alpha for a deterministic fee spike.
        SupaRoles roles = new SupaRoles(address(this), address(this));
        lvrPlugin.setRoles(ISupaRoles(address(roles)));

        manager.initialize(lvrPoolKey, 1 << 96, "");
        PoolId poolId = lvrPoolKey.toId();

        (,, uint16 cardinalityNext) = oracle.states(poolId);
        assertEq(cardinalityNext, 64, "oracle ring grown at init");

        harness.execute(abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, lvrPoolKey, uint256(10_000_000)));

        // Swap moves pool tick; afterSwap must persist the post-swap tick.
        // Sized to stay inside [-120, 120] liquidity (~60k token0 capacity). With SDX-004 gap crossing an
        // oversized exact-in swap now runs to the price limit instead of silently partial-filling.
        harness.execute(abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(20_000)));
        int24 tickAfterSwap1 = Slot0Library.tick(manager.getSlot0(poolId));
        assertEq(oracle.latestTicks(poolId), tickAfterSwap1, "oracle tick must match post-swap slot0");

        // Amplify sensitivity, then inject a sharp oracle tick jump over the TWAP window.
        lvrPlugin.setVolatilityAlpha(lvrPoolKey, 10_000);
        vm.warp(block.timestamp + 12);
        int24 spikedTick = tickAfterSwap1 + 200;
        vm.prank(address(lvrPlugin));
        oracle.write(poolId, uint32(block.timestamp), spikedTick, 1_000_000);

        vm.recordLogs();
        harness.execute(abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(10_000)));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        uint24 observedFee = _feeFromDynamicFeeUpdated(entries, poolId);
        assertGt(observedFee, 3000, "adaptive fee should elevate under rapid tick volatility");

        // Calm the signal (alpha=0 ⇒ no vol surcharge) and wait ≥16 half-lives for full decay.
        lvrPlugin.setVolatilityAlpha(lvrPoolKey, 0);
        vm.warp(block.timestamp + 192);
        vm.prank(address(lvrPlugin));
        oracle.write(poolId, uint32(block.timestamp), spikedTick, 1_000_000);

        vm.recordLogs();
        harness.execute(abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(5_000)));
        entries = vm.getRecordedLogs();
        uint24 decayedFee = _feeFromDynamicFeeUpdated(entries, poolId);
        assertLe(decayedFee, observedFee, "fee should not increase after idle half-lives");
        assertEq(decayedFee, 3000, "fee decays back to base after long idle");
    }

    function _feeFromDynamicFeeUpdated(Vm.Log[] memory entries, PoolId poolId) internal pure returns (uint24 fee) {
        // PoolId underlying type is bytes32 in the event ABI.
        bytes32 topic0 = keccak256("DynamicFeeUpdated(bytes32,uint24,uint24,uint24,uint32)");
        for (uint256 i; i < entries.length; ++i) {
            if (
                entries[i].topics.length > 1 && entries[i].topics[0] == topic0
                    && entries[i].topics[1] == PoolId.unwrap(poolId)
            ) {
                (, uint24 newFee,,) = abi.decode(entries[i].data, (uint24, uint24, uint24, uint32));
                return newFee;
            }
        }
        revert("DynamicFeeUpdated not found");
    }

    function test_endToEndAntiJITLifecycle() public {
        manager.initialize(jitPoolKey, 1 << 96, "");

        // Passive LP stays in-range so confiscated fees redistribute via fee growth.
        PluginIntegrationHarness passive = new PluginIntegrationHarness(vault, manager);
        MockPluginToken(Currency.unwrap(currency0)).mint(address(passive), 100_000_000 ether);
        MockPluginToken(Currency.unwrap(currency1)).mint(address(passive), 100_000_000 ether);
        passive.execute(abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, jitPoolKey, uint256(20_000_000)));

        // JIT attacker adds tight liquidity
        harness.execute(abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, jitPoolKey, uint256(5_000_000)));

        bytes32 posKey = keccak256(abi.encodePacked(address(harness), int24(-120), int24(120), bytes32(0)));
        (uint32 lastBlock,, uint128 liq) = jitPlugin.residencies(jitPoolKey.toId(), posKey);
        assertEq(lastBlock, uint32(block.number));
        assertEq(liq, 5_000_000);

        // Accrue fees against both LPs
        harness.execute(abi.encode(PluginIntegrationHarness.Action.SWAP, jitPoolKey, uint256(100_000)));

        (uint256 g0Before,) = clamm.getFeeGrowthGlobal(jitPoolKey.toId());

        // Same-block remove: principal returned, fees fully unvested → feeGrowth bump
        uint256 bal0Before = MockPluginToken(Currency.unwrap(currency0)).balanceOf(address(harness));
        uint256 bal1Before = MockPluginToken(Currency.unwrap(currency1)).balanceOf(address(harness));

        harness.execute(abi.encode(PluginIntegrationHarness.Action.REMOVE_LIQUIDITY, jitPoolKey, uint256(5_000_000)));

        uint256 bal0After = MockPluginToken(Currency.unwrap(currency0)).balanceOf(address(harness));
        uint256 bal1After = MockPluginToken(Currency.unwrap(currency1)).balanceOf(address(harness));
        // Principal returned (balances increase); fees confiscated so growth rises for remaining LP.
        assertTrue(bal0After > bal0Before || bal1After > bal1Before, "principal must be returned");

        (uint256 g0After,) = clamm.getFeeGrowthGlobal(jitPoolKey.toId());
        assertGt(g0After, g0Before, "unvested JIT fees must redistribute via fee growth");

        (,, uint128 remainingLiq) = jitPlugin.residencies(jitPoolKey.toId(), posKey);
        assertEq(remainingLiq, 0);
    }

    function test_endToEndAntiJITFullVestKeepsFees() public {
        manager.initialize(jitPoolKey, 1 << 96, "");

        // Keep a residual passive LP so remove doesn't leave unsettled fee-growth edge cases.
        PluginIntegrationHarness passive = new PluginIntegrationHarness(vault, manager);
        MockPluginToken(Currency.unwrap(currency0)).mint(address(passive), 100_000_000 ether);
        MockPluginToken(Currency.unwrap(currency1)).mint(address(passive), 100_000_000 ether);
        passive.execute(abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, jitPoolKey, uint256(20_000_000)));

        harness.execute(abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, jitPoolKey, uint256(5_000_000)));
        harness.execute(abi.encode(PluginIntegrationHarness.Action.SWAP, jitPoolKey, uint256(50_000)));

        vm.roll(block.number + 3); // minResidencyBlocks = 3

        (uint256 g0Before,) = clamm.getFeeGrowthGlobal(jitPoolKey.toId());
        uint256 proto0Before = manager.protocolFeesAccrued(currency0);
        uint256 proto1Before = manager.protocolFeesAccrued(currency1);

        harness.execute(abi.encode(PluginIntegrationHarness.Action.REMOVE_LIQUIDITY, jitPoolKey, uint256(5_000_000)));

        (uint256 g0After,) = clamm.getFeeGrowthGlobal(jitPoolKey.toId());
        assertEq(g0After, g0Before, "fully vested exit must not redistribute fees");
        assertEq(manager.protocolFeesAccrued(currency0), proto0Before);
        assertEq(manager.protocolFeesAccrued(currency1), proto1Before);
    }
}
