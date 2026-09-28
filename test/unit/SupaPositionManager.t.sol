// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
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

        posManager = new SupaPositionManager(manager, vault);

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
            hookData: ""
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
            hookData: ""
        });
        (uint256 tokenId, , , ) = posManager.mint(mintParams);

        // Increase liquidity
        ISupaPositionManager.IncreaseLiquidityParams memory incParams = ISupaPositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: 5 ether,
            amount0Max: 5 ether,
            amount1Max: 5 ether,
            deadline: block.timestamp + 100,
            hookData: ""
        });
        (uint128 totalLiq, , ) = posManager.increaseLiquidity(incParams);
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
            hookData: ""
        });
        (uint256 tokenId, , , ) = posManager.mint(mintParams);

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
            hookData: ""
        });
        (uint256 tokenId, , , ) = posManager.mint(mintParams);

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
}
