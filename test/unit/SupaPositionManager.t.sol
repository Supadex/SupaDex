// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";

contract MockPosToken {
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
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract SupaPositionManagerTest is Test {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    CLAMMEngine public clammEngine;
    BinAMMEngine public binEngine;
    StableAMMEngine public stableEngine;
    SupaPositionManager public posManager;

    MockPosToken public rawToken0;
    MockPosToken public rawToken1;
    Currency public token0;
    Currency public token1;

    PoolKey public poolKey;
    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    address alice = address(0xAAAA);
    address bob = address(0xBBBB);

    function setUp() public {
        vault = new SupaVault(address(this));
        clammEngine = new CLAMMEngine();
        binEngine = new BinAMMEngine();
        stableEngine = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clammEngine, binEngine, stableEngine);
        vault.setPoolManager(address(manager), true);

        PositionNFTDescriptor nftDescriptor = new PositionNFTDescriptor();
        posManager = new SupaPositionManager(manager, vault, address(nftDescriptor));

        MockPosToken t0 = new MockPosToken("Token 0", "TK0");
        MockPosToken t1 = new MockPosToken("Token 1", "TK1");

        address a0 = address(t0);
        address a1 = address(t1);
        if (a0 > a1) (a0, a1) = (a1, a0);

        rawToken0 = MockPosToken(a0);
        rawToken1 = MockPosToken(a1);
        token0 = Currency.wrap(a0);
        token1 = Currency.wrap(a1);

        poolKey = PoolKey({
            currency0: token0,
            currency1: token1,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolKey, SQRT_RATIO_1_1, "");

        rawToken0.mint(alice, 1000 ether);
        rawToken1.mint(alice, 1000 ether);
        rawToken0.mint(bob, 1000 ether);
        rawToken1.mint(bob, 1000 ether);

        vm.prank(alice);
        rawToken0.approve(address(posManager), type(uint256).max);
        vm.prank(alice);
        rawToken1.approve(address(posManager), type(uint256).max);

        vm.prank(bob);
        rawToken0.approve(address(posManager), type(uint256).max);
        vm.prank(bob);
        rawToken1.approve(address(posManager), type(uint256).max);
    }

    function test_mintPositionNFT() public {
        vm.startPrank(alice);

        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = posManager.mint(params);
        assertEq(tokenId, 1);
        assertEq(liquidity, 10 ether);
        assertTrue(amount0 > 0);
        assertTrue(amount1 > 0);
        assertEq(posManager.ownerOf(tokenId), alice);

        ISupaPositionManager.PositionInfo memory info = posManager.positions(tokenId);
        assertEq(info.liquidity, 10 ether);
        assertEq(info.tickLower, -120);
        assertEq(info.tickUpper, 120);

        vm.stopPrank();
    }

    function test_tokenURI_obsidianLattice() public {
        vm.startPrank(alice);

        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });

        (uint256 tokenId,,,) = posManager.mint(params);
        string memory uri = posManager.tokenURI(tokenId);

        // On-chain metadata (not dead api.supadex.io link)
        assertTrue(bytes(uri).length > 100);
        assertEq(bytes(uri)[0], bytes1("d")); // data:...
        // Must contain data URI prefix
        bytes memory uriBytes = bytes(uri);
        bytes memory prefix = bytes("data:application/json;base64,");
        for (uint256 i; i < prefix.length; i++) {
            assertEq(uriBytes[i], prefix[i]);
        }

        vm.stopPrank();
    }

    function test_increaseAndDecreaseLiquidity() public {
        vm.startPrank(alice);

        ISupaPositionManager.MintParams memory mintParams = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });
        (uint256 tokenId,,,) = posManager.mint(mintParams);

        // Increase liquidity
        ISupaPositionManager.IncreaseLiquidityParams memory incParams = ISupaPositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: 5 ether,
            amount0Max: 5 ether,
            amount1Max: 5 ether,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });
        (uint128 totalLiq,,) = posManager.increaseLiquidity(incParams);
        assertEq(totalLiq, 15 ether);

        // Decrease partial liquidity
        ISupaPositionManager.DecreaseLiquidityParams memory decParams = ISupaPositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: 5 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            hookData: ""
        });
        (uint256 dec0, uint256 dec1) = posManager.decreaseLiquidity(decParams);
        assertTrue(dec0 > 0);
        assertTrue(dec1 > 0);

        ISupaPositionManager.PositionInfo memory info = posManager.positions(tokenId);
        assertEq(info.liquidity, 10 ether);

        vm.stopPrank();
    }

    function test_transferNFTTransfersAuthority() public {
        vm.prank(alice);
        ISupaPositionManager.MintParams memory mintParams = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });
        (uint256 tokenId,,,) = posManager.mint(mintParams);

        // Transfer NFT from Alice to Bob
        vm.prank(alice);
        posManager.transferFrom(alice, bob, tokenId);
        assertEq(posManager.ownerOf(tokenId), bob);

        // Alice can no longer decrease liquidity
        ISupaPositionManager.DecreaseLiquidityParams memory decParams = ISupaPositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: 5 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            hookData: ""
        });

        vm.prank(alice);
        vm.expectRevert();
        posManager.decreaseLiquidity(decParams);

        // Bob can decrease liquidity
        vm.prank(bob);
        (uint256 dec0, uint256 dec1) = posManager.decreaseLiquidity(decParams);
        assertTrue(dec0 > 0);
        assertTrue(dec1 > 0);
    }

    function test_burnEmptyPosition() public {
        vm.startPrank(alice);

        ISupaPositionManager.MintParams memory mintParams = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });
        (uint256 tokenId,,,) = posManager.mint(mintParams);

        // Attempting to burn active position reverts
        vm.expectRevert();
        posManager.burn(tokenId);

        // Withdraw 100% of liquidity
        ISupaPositionManager.DecreaseLiquidityParams memory decParams = ISupaPositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: 10 ether,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            hookData: ""
        });
        posManager.decreaseLiquidity(decParams);

        // Now burn succeeds
        posManager.burn(tokenId);

        // Token no longer exists
        vm.expectRevert();
        posManager.ownerOf(tokenId);

        vm.stopPrank();
    }

    function test_swapAccruesFees_syncAndCollect() public {
        // Wide-range liquidity so a small swap stays in-range
        vm.startPrank(alice);
        ISupaPositionManager.MintParams memory mintParams = ISupaPositionManager.MintParams({
            poolKey: poolKey,
            tickLower: -887220,
            tickUpper: 887220,
            liquidity: 100 ether,
            amount0Max: 1000 ether,
            amount1Max: 1000 ether,
            recipient: alice,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });
        (uint256 tokenId,,,) = posManager.mint(mintParams);
        vm.stopPrank();

        // Bob swaps token0 -> token1 through the pool (pays fee)
        SwapHelper swapper = new SwapHelper(vault, manager);
        rawToken0.mint(address(swapper), 10 ether);

        vm.prank(address(swapper));
        swapper.swap(poolKey, true, 1 ether);

        // Before sync, tokensOwed is still zero (fees live in engine fee growth)
        ISupaPositionManager.PositionInfo memory beforeSync = posManager.positions(tokenId);
        assertEq(beforeSync.tokensOwed0, 0);
        assertEq(beforeSync.tokensOwed1, 0);

        // Sync credits tokensOwed from fee growth
        vm.prank(alice);
        (uint256 fees0, uint256 fees1) = posManager.syncFees(tokenId);
        assertTrue(fees0 > 0 || fees1 > 0, "expected accrued fees after swap");

        ISupaPositionManager.PositionInfo memory afterSync = posManager.positions(tokenId);
        assertEq(afterSync.tokensOwed0, fees0);
        assertEq(afterSync.tokensOwed1, fees1);

        uint256 alice0Before = rawToken0.balanceOf(alice);
        uint256 alice1Before = rawToken1.balanceOf(alice);

        vm.prank(alice);
        (uint256 collected0, uint256 collected1) = posManager.collect(
            ISupaPositionManager.CollectParams({
                tokenId: tokenId,
                recipient: alice,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        assertEq(collected0, fees0);
        assertEq(collected1, fees1);
        assertEq(rawToken0.balanceOf(alice), alice0Before + collected0);
        assertEq(rawToken1.balanceOf(alice), alice1Before + collected1);

        ISupaPositionManager.PositionInfo memory afterCollect = posManager.positions(tokenId);
        assertEq(afterCollect.tokensOwed0, 0);
        assertEq(afterCollect.tokensOwed1, 0);
    }
}

contract SwapHelper is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external {
        vault.unlock(abi.encode(key, zeroForOne, amountIn));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? uint160(4295128740) : uint160(1461446703485210103287273052203988822378723970341)
        });

        BalanceDelta delta = manager.swap(key, params, "");

        if (delta.amount0() > 0) {
            uint256 amt = uint256(uint128(delta.amount0()));
            MockPosToken(Currency.unwrap(key.currency0)).transfer(address(vault), amt);
            vault.settle(key.currency0);
        }
        if (delta.amount1() > 0) {
            uint256 amt = uint256(uint128(delta.amount1()));
            MockPosToken(Currency.unwrap(key.currency1)).transfer(address(vault), amt);
            vault.settle(key.currency1);
        }
        if (delta.amount0() < 0) {
            vault.take(key.currency0, address(this), uint256(uint128(-delta.amount0())));
        }
        if (delta.amount1() < 0) {
            vault.take(key.currency1, address(this), uint256(uint128(-delta.amount1())));
        }

        return "";
    }
}
