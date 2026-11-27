// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract StableExitToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Minimal swap actor so the first LP can exit after trading activity
/// (fees accrued) as well as on a fresh pool.
contract StableExitSwapper is IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    StableExitToken public t0;
    StableExitToken public t1;

    constructor(SupaVault _vault, SupaPoolManager _manager, StableExitToken _t0, StableExitToken _t1) {
        vault = _vault;
        manager = _manager;
        t0 = _t0;
        t1 = _t1;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, int256 amount) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta delta = manager.swap(
            key, IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: amount, sqrtPriceLimitX96: 0}), ""
        );
        _leg(key.currency0, delta.amount0());
        _leg(key.currency1, delta.amount1());
        return "";
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amount) external {
        vault.unlock(abi.encode(key, zeroForOne, amount));
    }

    function _leg(Currency currency, int128 amount) internal {
        if (amount > 0) {
            vault.sync(currency);
            StableExitToken(Currency.unwrap(currency)).transfer(address(vault), uint256(uint128(amount)));
            vault.settle(currency);
        } else if (amount < 0) {
            vault.take(currency, address(this), uint256(uint128(-amount)));
        }
    }
}

/// @title T-7 (L-02): first Stable LP via SupaPositionManager can fully exit
/// @notice The L-02 fix (engine credits shares - MINIMUM_LIQUIDITY, the NFT
/// stores the credited amount) is exercised end-to-end here: first mint via
/// the position manager, full decreaseLiquidity, then burn(). The base case
/// also exists as test_stableFirstLpFullExitBurnsNft in AuditRemediation;
/// this file extends it with a fuzz over share amounts, a second LP after the
/// first has fully exited, and a full exit after swaps have accrued fees.
/// If any of these FAIL, do not weaken the test — the L-02 fix is incomplete.
contract StableFirstLpFullExitTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    SupaPositionManager internal pos;
    StableAMMEngine internal stable;
    StableExitToken internal t0;
    StableExitToken internal t1;
    PoolKey internal key;

    function setUp() public {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        stable = StableAMMEngine(address(manager.stableEngine()));
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));
        pos = new SupaPositionManager(manager, vault, address(new PositionNFTDescriptor()));

        StableExitToken x = new StableExitToken("A", "A");
        StableExitToken y = new StableExitToken("B", "B");
        if (address(x) > address(y)) (x, y) = (y, x);
        t0 = x;
        t1 = y;

        key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 100,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
        manager.initializeWithParams(key, SQRT_1_1, abi.encode(uint256(100)), "");
    }

    function _mintFirst(uint128 shares) internal returns (uint256 tokenId, uint128 credited) {
        // Fund and cap at 2x shares: the first deposit needs exactly `shares`
        // per side, but a later deposit's proportional amounts can round above
        // `shares` when reserves carry removal dust.
        uint128 cap = uint128(uint256(shares) * 2);
        t0.mint(address(this), cap);
        t1.mint(address(this), cap);
        t0.approve(address(pos), type(uint256).max);
        t1.approve(address(pos), type(uint256).max);
        (tokenId, credited,,) = pos.mint(
            ISupaPositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 0,
                liquidity: shares,
                amount0Max: cap,
                amount1Max: cap,
                recipient: address(this),
                deadline: block.timestamp + 1 days,
                hookData: "",
                payWithClaims: false
            })
        );
    }

    function _decreaseFull(uint256 tokenId, uint128 liquidity) internal {
        pos.decreaseLiquidity(
            ISupaPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 days,
                hookData: "",
                recipient: address(this),
                receiveAsClaims: false
            })
        );
    }

    /// @notice Fuzz over first-deposit sizes: every size above MINIMUM_LIQUIDITY
    /// must mint (shares - 1000) of credited liquidity, fully decrease, and burn.
    function testFuzz_firstLpFullExitBurnsNft(uint128 rawShares) public {
        uint128 shares = uint128(bound(uint256(rawShares), 1001, 100_000));
        (uint256 tokenId, uint128 credited) = _mintFirst(shares);

        assertEq(credited, shares - 1000, "MINIMUM_LIQUIDITY is not part of the NFT");
        assertEq(pos.positions(tokenId).liquidity, shares - 1000);

        _decreaseFull(tokenId, credited);
        assertEq(pos.positions(tokenId).liquidity, 0, "position not fully decreased");

        pos.burn(tokenId);
        vm.expectRevert();
        pos.ownerOf(tokenId);

        assertEq(stable.getLiquidity(key.toId()), 1000, "only the locked minimum remains");
    }

    /// @notice The MINIMUM_LIQUIDITY lock happens exactly once: after the first
    /// LP has fully exited and burned, a second LP's deposit is credited in
    /// full (no second 1000-share haircut) and can also fully exit and burn.
    function test_secondLpAfterFirstExitIsCreditedInFull() public {
        (uint256 firstId, uint128 firstCredited) = _mintFirst(10_000);
        assertEq(firstCredited, 9_000);
        _decreaseFull(firstId, firstCredited);
        pos.burn(firstId);

        (uint256 secondId, uint128 secondCredited) = _mintFirst(10_000);
        assertEq(secondCredited, 10_000, "second LP must not pay MINIMUM_LIQUIDITY again");
        assertEq(pos.positions(secondId).liquidity, 10_000);

        _decreaseFull(secondId, secondCredited);
        assertEq(pos.positions(secondId).liquidity, 0);
        pos.burn(secondId);
        assertEq(stable.getLiquidity(key.toId()), 1000, "only the locked minimum remains");
    }

    /// @notice Full exit still works after swaps have moved the price and
    /// accrued fees to the position.
    function test_firstLpFullExitAfterSwaps() public {
        (uint256 tokenId, uint128 credited) = _mintFirst(100_000);
        assertEq(credited, 99_000);

        StableExitSwapper swapper = new StableExitSwapper(vault, manager, t0, t1);
        t0.mint(address(swapper), 10_000);
        t1.mint(address(swapper), 10_000);
        swapper.swap(key, true, 1_000);
        swapper.swap(key, false, 1_000);

        uint256 bal0Before = t0.balanceOf(address(this));
        uint256 bal1Before = t1.balanceOf(address(this));
        _decreaseFull(tokenId, credited);
        assertEq(pos.positions(tokenId).liquidity, 0);
        assertGt(t0.balanceOf(address(this)), bal0Before, "principal + fees not returned (token0)");
        assertGt(t1.balanceOf(address(this)), bal1Before, "principal + fees not returned (token1)");

        pos.burn(tokenId);
        vm.expectRevert();
        pos.ownerOf(tokenId);
        assertEq(stable.getLiquidity(key.toId()), 1000, "only the locked minimum remains");
    }
}
