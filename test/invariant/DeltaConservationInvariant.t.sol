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
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract MockInvariantToken {
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
        require(balanceOf[msg.sender] >= amount, "MockInvariantToken: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract DeltaConservationHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    PoolKey public key;
    MockInvariantToken public token0;
    MockInvariantToken public token1;

    constructor(
        SupaVault _vault,
        SupaPoolManager _manager,
        PoolKey memory _key,
        MockInvariantToken _token0,
        MockInvariantToken _token1
    ) {
        vault = _vault;
        manager = _manager;
        key = _key;
        token0 = _token0;
        token1 = _token1;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint256 amount) = abi.decode(data, (uint8, uint256));

        if (action == 0) {
            // Modify Liquidity
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(amount),
                salt: bytes32(0)
            });
            (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");
            if (delta.amount0() > 0) {
                token0.transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() > 0) {
                token1.transfer(address(vault), uint128(delta.amount1()));
                vault.settle(key.currency1);
            }
        } else if (action == 1) {
            // Swap
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(amount),
                sqrtPriceLimitX96: 0
            });
            BalanceDelta delta = manager.swap(key, swapParams, "");
            if (delta.amount0() > 0) {
                token0.transfer(address(vault), uint128(delta.amount0()));
                vault.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                vault.take(key.currency1, address(this), uint128(-delta.amount1()));
            }
        }
        return "";
    }

    function performModifyLiquidity(uint256 amount) external {
        amount = bound(amount, 1_000, 100_000 ether);
        token0.mint(address(this), amount * 2);
        token1.mint(address(this), amount * 2);
        vault.unlock(abi.encode(uint8(0), amount));
    }

    function performSwap(uint256 amount) external {
        amount = bound(amount, 100, 10_000 ether);
        token0.mint(address(this), amount * 2);
        vault.unlock(abi.encode(uint8(1), amount));
    }
}

contract DeltaConservationInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    DeltaConservationHandler public handler;
    MockInvariantToken public token0;
    MockInvariantToken public token1;
    PoolKey public key;

    function setUp() public {
        vault = new SupaVault(address(this));
        CLAMMEngine clamm = new CLAMMEngine();
        BinAMMEngine binAmm = new BinAMMEngine();
        StableAMMEngine stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        MockInvariantToken tA = new MockInvariantToken("Token A", "TKNA");
        MockInvariantToken tB = new MockInvariantToken("Token B", "TKNB");

        Currency c0;
        Currency c1;
        if (address(tA) < address(tB)) {
            token0 = tA;
            token1 = tB;
            c0 = Currency.wrap(address(tA));
            c1 = Currency.wrap(address(tB));
        } else {
            token0 = tB;
            token1 = tA;
            c0 = Currency.wrap(address(tB));
            c1 = Currency.wrap(address(tA));
        }

        key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });

        manager.initialize(key, 1 << 96, "");
        handler = new DeltaConservationHandler(vault, manager, key, token0, token1);

        // Seed initial liquidity in pool so swaps can execute
        handler.performModifyLiquidity(1_000_000 ether);

        targetContract(address(handler));
    }

    /// @notice Invariant: Transient currency deltas must always equal 0 outside of active unlock sessions.
    function invariant_deltaConservation() public view {
        assertEq(vault.getCurrencyDelta(address(handler), key.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(handler), key.currency1), 0);
        assertFalse(vault.isUnlocked());
    }
}
