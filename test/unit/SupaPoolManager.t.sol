// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract MockToken {
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
        require(balanceOf[msg.sender] >= amount, "MockToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PoolManagerTestHarness is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    enum Action {
        ADD_LIQUIDITY,
        SWAP,
        DONATE
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

            // Transfer tokens to vault and settle
            if (delta.amount0() > 0) {
                MockToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() > 0) {
                MockToken(Currency.unwrap(key.currency1)).transfer(address(vault), uint128(delta.amount1()));
                vault.settle(key.currency1);
            }
        } else if (action == Action.SWAP) {
            IPoolManager.SwapParams memory swapParams =
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: int256(val), sqrtPriceLimitX96: 0});

            BalanceDelta delta = manager.swap(key, swapParams, "");

            // Settle input token0
            if (delta.amount0() > 0) {
                MockToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            // Take output token1
            if (delta.amount1() < 0) {
                vault.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        } else if (action == Action.DONATE) {
            manager.donate(key, val, val, "");
            MockToken(Currency.unwrap(key.currency0)).transfer(address(vault), val);
            vault.settle(key.currency0);
            MockToken(Currency.unwrap(key.currency1)).transfer(address(vault), val);
            vault.settle(key.currency1);
        }

        return abi.encode(true);
    }
}

contract SupaPoolManagerTest is Test {
    SupaVault public vault;
    SupaPoolManager public manager;
    CLAMMEngine public clamm;
    BinAMMEngine public binAmm;
    StableAMMEngine public stableAmm;

    PoolManagerTestHarness public harness;
    MockToken public tokenA;
    MockToken public tokenB;
    Currency public currency0;
    Currency public currency1;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    function setUp() public {
        vault = new SupaVault(address(this));
        clamm = new CLAMMEngine();
        binAmm = new BinAMMEngine();
        stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        harness = new PoolManagerTestHarness(vault, manager);

        tokenA = new MockToken("Token A", "TKNA");
        tokenB = new MockToken("Token B", "TKNB");

        // Order currencies strictly
        if (address(tokenA) < address(tokenB)) {
            currency0 = Currency.wrap(address(tokenA));
            currency1 = Currency.wrap(address(tokenB));
        } else {
            currency0 = Currency.wrap(address(tokenB));
            currency1 = Currency.wrap(address(tokenA));
        }

        clammKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });

        binKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000,
            tickSpacing: 10,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });

        stableKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 400,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });

        MockToken(Currency.unwrap(currency0)).mint(address(harness), 10_000_000 ether);
        MockToken(Currency.unwrap(currency1)).mint(address(harness), 10_000_000 ether);
    }

    function test_initializePoolsAcrossEngines() public {
        int24 tickClamm = manager.initialize(clammKey, 1 << 96, "");
        assertEq(tickClamm, 0);

        int24 tickBin = manager.initialize(binKey, 1 << 96, "");
        assertEq(tickBin, int24(uint24(8388608))); // CENTER_BIN_ID encoded as int24

        int24 tickStable = manager.initialize(stableKey, 1 << 96, "");
        assertEq(tickStable, 0);
    }

    function test_clammAddLiquidityAndSwapEndToEnd() public {
        manager.initialize(clammKey, 1 << 96, "");

        // 1. Add Liquidity
        bytes memory addData = abi.encode(PoolManagerTestHarness.Action.ADD_LIQUIDITY, clammKey, uint256(1_000_000));
        harness.execute(addData);

        // 2. Swap token0 for token1
        bytes memory swapData = abi.encode(PoolManagerTestHarness.Action.SWAP, clammKey, uint256(1000));
        harness.execute(swapData);
    }

    function test_donateEndToEnd() public {
        manager.initialize(clammKey, 1 << 96, "");

        bytes memory donateData = abi.encode(PoolManagerTestHarness.Action.DONATE, clammKey, uint256(500 ether));
        harness.execute(donateData);
    }
}
