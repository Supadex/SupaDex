// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";

contract MockPosInvToken {
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
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Allowance");
            allowance[from][msg.sender] -= amount;
        }
        require(balanceOf[from] >= amount, "Balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract PositionNFTHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    SupaPositionManager public posManager;
    PoolKey public key;

    MockPosInvToken public token0;
    MockPosInvToken public token1;

    uint256[] public mintedTokenIds;
    mapping(uint256 => uint128) public activeLiquidityOfToken;
    uint256 public totalMinted;
    uint256 public totalBurned;

    address[] public actors;

    constructor(
        SupaVault _vault,
        SupaPoolManager _manager,
        SupaPositionManager _posManager,
        PoolKey memory _key,
        MockPosInvToken _token0,
        MockPosInvToken _token1
    ) {
        vault = _vault;
        manager = _manager;
        posManager = _posManager;
        key = _key;
        token0 = _token0;
        token1 = _token1;

        actors.push(address(0x1111));
        actors.push(address(0x2222));
        actors.push(address(0x3333));
    }

    function mintPosition(uint8 actorIdx, uint128 liquidity) external {
        liquidity = uint128(bound(liquidity, 1_000, 10_000 ether));
        address actor = actors[actorIdx % actors.length];

        token0.mint(actor, uint256(liquidity) * 4);
        token1.mint(actor, uint256(liquidity) * 4);

        vm.startPrank(actor);
        token0.approve(address(posManager), type(uint256).max);
        token1.approve(address(posManager), type(uint256).max);

        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: key,
            tickLower: -120,
            tickUpper: 120,
            liquidity: liquidity,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            recipient: actor,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });

        (uint256 tokenId, uint128 liq,,) = posManager.mint(params);
        vm.stopPrank();

        mintedTokenIds.push(tokenId);
        activeLiquidityOfToken[tokenId] = liq;
        totalMinted++;
    }

    function increasePosition(uint256 idIdx, uint128 addLiquidity) external {
        if (mintedTokenIds.length == 0) return;
        uint256 tokenId = mintedTokenIds[idIdx % mintedTokenIds.length];
        if (activeLiquidityOfToken[tokenId] == 0) return;

        addLiquidity = uint128(bound(addLiquidity, 100, 5_000 ether));
        address owner = posManager.ownerOf(tokenId);

        token0.mint(owner, uint256(addLiquidity) * 4);
        token1.mint(owner, uint256(addLiquidity) * 4);

        vm.startPrank(owner);
        token0.approve(address(posManager), type(uint256).max);
        token1.approve(address(posManager), type(uint256).max);

        ISupaPositionManager.IncreaseLiquidityParams memory params = ISupaPositionManager.IncreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: addLiquidity,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            deadline: block.timestamp + 100,
            hookData: "",
        payWithClaims: false
        });

        (uint128 liq,,) = posManager.increaseLiquidity(params);
        vm.stopPrank();

        activeLiquidityOfToken[tokenId] += liq;
    }

    function decreasePosition(uint256 idIdx, uint128 subLiquidity) external {
        if (mintedTokenIds.length == 0) return;
        uint256 tokenId = mintedTokenIds[idIdx % mintedTokenIds.length];
        uint128 currentLiq = activeLiquidityOfToken[tokenId];
        if (currentLiq == 0) return;

        subLiquidity = uint128(bound(subLiquidity, 1, currentLiq));
        address owner = posManager.ownerOf(tokenId);

        vm.startPrank(owner);
        ISupaPositionManager.DecreaseLiquidityParams memory params = ISupaPositionManager.DecreaseLiquidityParams({
            tokenId: tokenId,
            liquidity: subLiquidity,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp + 100,
            hookData: ""
        });

        posManager.decreaseLiquidity(params);
        vm.stopPrank();

        activeLiquidityOfToken[tokenId] -= subLiquidity;
    }

    function collectFees(uint256 idIdx) external {
        if (mintedTokenIds.length == 0) return;
        uint256 tokenId = mintedTokenIds[idIdx % mintedTokenIds.length];
        if (!_tokenExists(tokenId)) return;

        address owner = posManager.ownerOf(tokenId);

        vm.startPrank(owner);
        ISupaPositionManager.CollectParams memory params = ISupaPositionManager.CollectParams({
            tokenId: tokenId, recipient: owner, amount0Max: type(uint128).max, amount1Max: type(uint128).max
        });

        posManager.collect(params);
        vm.stopPrank();
    }

    function burnPosition(uint256 idIdx) external {
        if (mintedTokenIds.length == 0) return;
        uint256 tokenId = mintedTokenIds[idIdx % mintedTokenIds.length];
        if (activeLiquidityOfToken[tokenId] > 0) return;
        if (!_tokenExists(tokenId)) return;

        address owner = posManager.ownerOf(tokenId);

        vm.startPrank(owner);
        posManager.burn(tokenId);
        vm.stopPrank();

        totalBurned++;
    }

    function _tokenExists(uint256 tokenId) internal view returns (bool) {
        try posManager.ownerOf(tokenId) returns (address) {
            return true;
        } catch {
            return false;
        }
    }
}

contract PositionNFTInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    SupaPositionManager public posManager;
    PositionNFTHandler public handler;

    PoolKey public key;
    MockPosInvToken public token0;
    MockPosInvToken public token1;

    function setUp() public {
        vault = new SupaVault(address(this));
        CLAMMEngine clamm = new CLAMMEngine();
        BinAMMEngine binAmm = new BinAMMEngine();
        StableAMMEngine stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        PositionNFTDescriptor nftDescriptor = new PositionNFTDescriptor();
        posManager = new SupaPositionManager(manager, vault, address(nftDescriptor));

        MockPosInvToken tA = new MockPosInvToken("Token A", "TKNA");
        MockPosInvToken tB = new MockPosInvToken("Token B", "TKNB");

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
            currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
        });

        manager.initialize(key, 1 << 96, "");

        handler = new PositionNFTHandler(vault, manager, posManager, key, token0, token1);

        targetContract(address(handler));
    }

    /// @notice Invariant: PositionManager must never accumulate unsettled transient deltas.
    function invariant_positionManagerTransientDeltasZero() public view {
        assertEq(vault.getCurrencyDelta(address(posManager), key.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(posManager), key.currency1), 0);
        assertFalse(vault.isUnlocked());
    }

    /// @notice Invariant: PositionManager should never retain physical custody of tokens.
    function invariant_positionManagerZeroResidue() public view {
        assertEq(token0.balanceOf(address(posManager)), 0);
        assertEq(token1.balanceOf(address(posManager)), 0);
    }
}
