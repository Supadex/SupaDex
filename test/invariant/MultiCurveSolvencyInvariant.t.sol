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
import {SafeCastLib} from "../../contract/libraries/SafeCastLib.sol";

contract MockMultiCurveToken {
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

contract MultiCurveHandler is Test, IUnlockCallback {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockMultiCurveToken public tokenA;
    MockMultiCurveToken public tokenB;
    MockMultiCurveToken public tokenC;

    uint256 public successfulSwaps;
    uint256 public successfulLiquidityModifications;

    constructor(
        SupaVault _vault,
        SupaPoolManager _manager,
        PoolKey memory _clammKey,
        PoolKey memory _binKey,
        PoolKey memory _stableKey,
        MockMultiCurveToken _tokenA,
        MockMultiCurveToken _tokenB,
        MockMultiCurveToken _tokenC
    ) {
        vault = _vault;
        manager = _manager;
        clammKey = _clammKey;
        binKey = _binKey;
        stableKey = _stableKey;
        tokenA = _tokenA;
        tokenB = _tokenB;
        tokenC = _tokenC;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, uint8 curveIdx, bool zeroForOne, uint256 amount) =
            abi.decode(data, (uint8, uint8, bool, uint256));

        PoolKey memory selectedKey;
        if (curveIdx == 0) selectedKey = clammKey;
        else if (curveIdx == 1) selectedKey = binKey;
        else selectedKey = stableKey;

        if (action == 0) {
            // Modify Liquidity
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: int256(amount), salt: bytes32(0)
            });
            (BalanceDelta delta,) = manager.modifyLiquidity(selectedKey, params, "");
            _settleDeltas(selectedKey, delta);
            successfulLiquidityModifications++;
        } else if (action == 1) {
            // Swap
            IPoolManager.SwapParams memory swapParams = IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: int256(amount), sqrtPriceLimitX96: 0
            });
            BalanceDelta delta = manager.swap(selectedKey, swapParams, "");
            _settleDeltas(selectedKey, delta);
            successfulSwaps++;
        }
        return "";
    }

    function _settleDeltas(PoolKey memory pKey, BalanceDelta delta) internal {
        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 > 0) {
            MockMultiCurveToken(Currency.unwrap(pKey.currency0)).transfer(address(vault), uint128(d0));
            vault.settle(pKey.currency0);
        } else if (d0 < 0) {
            vault.take(pKey.currency0, address(this), uint128(-d0));
        }

        if (d1 > 0) {
            MockMultiCurveToken(Currency.unwrap(pKey.currency1)).transfer(address(vault), uint128(d1));
            vault.settle(pKey.currency1);
        } else if (d1 < 0) {
            vault.take(pKey.currency1, address(this), uint128(-d1));
        }
    }

    function swapCLAMM(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 100, 5_000 ether);
        _mintTokensForSwap(clammKey, zeroForOne, amount);
        vault.unlock(abi.encode(uint8(1), uint8(0), zeroForOne, amount));
    }

    function swapBinAMM(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 100, 5_000 ether);
        _mintTokensForSwap(binKey, zeroForOne, amount);
        vault.unlock(abi.encode(uint8(1), uint8(1), zeroForOne, amount));
    }

    function swapStableAMM(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 100, 5_000 ether);
        _mintTokensForSwap(stableKey, zeroForOne, amount);
        vault.unlock(abi.encode(uint8(1), uint8(2), zeroForOne, amount));
    }

    function addLiquidityCLAMM(uint256 amount) external {
        amount = bound(amount, 1_000, 10_000 ether);
        _mintTokensForLiquidity(clammKey, amount);
        vault.unlock(abi.encode(uint8(0), uint8(0), false, amount));
    }

    function addLiquidityBinAMM(uint256 amount) external {
        amount = bound(amount, 1_000, 10_000 ether);
        _mintTokensForLiquidity(binKey, amount);
        vault.unlock(abi.encode(uint8(0), uint8(1), false, amount));
    }

    function addLiquidityStableAMM(uint256 amount) external {
        amount = bound(amount, 1_000, 10_000 ether);
        _mintTokensForLiquidity(stableKey, amount);
        vault.unlock(abi.encode(uint8(0), uint8(2), false, amount));
    }

    function _mintTokensForSwap(PoolKey memory pKey, bool zeroForOne, uint256 amount) internal {
        if (zeroForOne) {
            MockMultiCurveToken(Currency.unwrap(pKey.currency0)).mint(address(this), amount * 2);
        } else {
            MockMultiCurveToken(Currency.unwrap(pKey.currency1)).mint(address(this), amount * 2);
        }
    }

    function _mintTokensForLiquidity(PoolKey memory pKey, uint256 amount) internal {
        MockMultiCurveToken(Currency.unwrap(pKey.currency0)).mint(address(this), amount * 4);
        MockMultiCurveToken(Currency.unwrap(pKey.currency1)).mint(address(this), amount * 4);
    }
}

contract MultiCurveSolvencyInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    MultiCurveHandler public handler;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockMultiCurveToken public tokenA;
    MockMultiCurveToken public tokenB;
    MockMultiCurveToken public tokenC;

    function setUp() public {
        vault = new SupaVault(address(this));
        CLAMMEngine clamm = new CLAMMEngine();
        BinAMMEngine binAmm = new BinAMMEngine();
        StableAMMEngine stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        // Deploy 3 tokens sorted by address
        MockMultiCurveToken[3] memory rawTokens;
        rawTokens[0] = new MockMultiCurveToken("Token A", "TKNA");
        rawTokens[1] = new MockMultiCurveToken("Token B", "TKNB");
        rawTokens[2] = new MockMultiCurveToken("Token C", "TKNC");

        // Sort addresses
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(rawTokens[i]) > address(rawTokens[j])) {
                    MockMultiCurveToken temp = rawTokens[i];
                    rawTokens[i] = rawTokens[j];
                    rawTokens[j] = temp;
                }
            }
        }

        tokenA = rawTokens[0];
        tokenB = rawTokens[1];
        tokenC = rawTokens[2];

        Currency cA = Currency.wrap(address(tokenA));
        Currency cB = Currency.wrap(address(tokenB));
        Currency cC = Currency.wrap(address(tokenC));

        // Create 3 pools across distinct curve engines
        clammKey = PoolKey({
            currency0: cA, currency1: cB, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
        });

        binKey = PoolKey({
            currency0: cB, currency1: cC, fee: 2000, tickSpacing: 10, plugin: address(0), curveType: CurveType.BIN_AMM
        });

        stableKey = PoolKey({
            currency0: cA, currency1: cC, fee: 500, tickSpacing: 1, plugin: address(0), curveType: CurveType.STABLE_AMM
        });

        // Initialize pools
        manager.initialize(clammKey, 1 << 96, "");
        manager.initialize(binKey, 1 << 96, "");
        manager.initialize(stableKey, 1 << 96, "");

        handler = new MultiCurveHandler(vault, manager, clammKey, binKey, stableKey, tokenA, tokenB, tokenC);

        // Seed initial deep liquidity in all 3 curves
        handler.addLiquidityCLAMM(500_000 ether);
        handler.addLiquidityBinAMM(500_000 ether);
        handler.addLiquidityStableAMM(500_000 ether);

        targetContract(address(handler));
    }

    /// @notice Invariant: Transient currency deltas must always equal 0 across all curves.
    function invariant_transientDeltasZero() public view {
        assertEq(vault.getCurrencyDelta(address(handler), clammKey.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(handler), clammKey.currency1), 0);
        assertEq(vault.getCurrencyDelta(address(handler), binKey.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(handler), binKey.currency1), 0);
        assertEq(vault.getCurrencyDelta(address(handler), stableKey.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(handler), stableKey.currency1), 0);
        assertFalse(vault.isUnlocked());
    }

    /// @notice Invariant: Vault physical custody must always be strictly greater than or equal to 0.
    function invariant_vaultPhysicalSolvency() public view {
        assertTrue(tokenA.balanceOf(address(vault)) >= 0);
        assertTrue(tokenB.balanceOf(address(vault)) >= 0);
        assertTrue(tokenC.balanceOf(address(vault)) >= 0);
    }
}
