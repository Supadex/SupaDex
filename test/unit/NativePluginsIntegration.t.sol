// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
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
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(val),
                salt: bytes32(0)
            });

            (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");

            if (delta.amount0() > 0) {
                MockPluginToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() > 0) {
                MockPluginToken(Currency.unwrap(key.currency1)).transfer(address(vault), uint128(delta.amount1()));
                vault.settle(key.currency1);
            }
        } else if (action == Action.REMOVE_LIQUIDITY) {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -int256(val),
                salt: bytes32(0)
            });

            (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");

            if (delta.amount0() < 0) {
                vault.take(key.currency0, address(this), uint128(-delta.amount0()));
            }
            if (delta.amount1() < 0) {
                vault.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        } else if (action == Action.SWAP) {
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(val),
                sqrtPriceLimitX96: 0
            });

            BalanceDelta delta = manager.swap(key, swapParams, "");

            if (delta.amount0() > 0) {
                MockPluginToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                vault.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        }

        return abi.encode(true);
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
        clamm = new CLAMMEngine();
        binAmm = new BinAMMEngine();
        stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        oracle = new VolatilityTWAPOracle();
        lvrPlugin = new LVRShieldPlugin(manager, oracle);
        jitPlugin = new AntiJITVestingPlugin(manager, 3); // 3 blocks residency

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
        manager.initialize(lvrPoolKey, 1 << 96, "");

        // 1. Add Liquidity
        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, lvrPoolKey, uint256(10_000_000))
        );

        // 2. Perform Swap 1 (elevates volatility state)
        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(1000))
        );

        // 3. Perform Rapid Follow-up Swap 2 in same timestamp
        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(500))
        );

        // 4. Advance time by 60 seconds (fee decays back to base fee)
        vm.warp(block.timestamp + 60);

        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.SWAP, lvrPoolKey, uint256(200))
        );
    }

    function test_endToEndAntiJITLifecycle() public {
        manager.initialize(jitPoolKey, 1 << 96, "");

        // 1. Add Liquidity
        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.ADD_LIQUIDITY, jitPoolKey, uint256(5_000_000))
        );

        // Verify residency tracking
        bytes32 posKey = keccak256(abi.encodePacked(address(harness), int24(-120), int24(120), bytes32(0)));
        (uint32 lastBlock, , uint128 liq) = jitPlugin.residencies(jitPoolKey.toId(), posKey);
        assertEq(lastBlock, uint32(block.number));
        assertEq(liq, 5_000_000);

        // 2. Immediate Removal (Same block JIT attempt) - should trigger penalty event
        vm.expectEmit(true, true, true, false);
        emit JITPenaltyLevied(
            jitPoolKey.toId(),
            address(harness),
            posKey,
            2_500_000, // 50% haircut
            0,
            3
        );

        harness.execute(
            abi.encode(PluginIntegrationHarness.Action.REMOVE_LIQUIDITY, jitPoolKey, uint256(5_000_000))
        );

        // Verify position liquidity reduced to 0
        (, , uint128 remainingLiq) = jitPlugin.residencies(jitPoolKey.toId(), posKey);
        assertEq(remainingLiq, 0);
    }
}
