// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {SupaQuoter} from "../../contract/periphery/SupaQuoter.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {ISupaQuoter} from "../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PathKeyLib} from "../../contract/periphery/libraries/PathKeyLib.sol";

contract MockQuoterToken {
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

contract QuoterLiquidityHelper is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external {
        vault.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)
        });

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");

        if (delta.amount0() > 0) {
            uint256 amount0 = uint256(uint128(delta.amount0()));
            MockQuoterToken(Currency.unwrap(key.currency0)).transfer(address(vault), amount0);
            vault.settle(key.currency0);
        }
        if (delta.amount1() > 0) {
            uint256 amount1 = uint256(uint128(delta.amount1()));
            MockQuoterToken(Currency.unwrap(key.currency1)).transfer(address(vault), amount1);
            vault.settle(key.currency1);
        }

        return "";
    }
}

contract SupaQuoterTest is Test {
    using PathKeyLib for bytes;
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    CLAMMEngine public clammEngine;
    BinAMMEngine public binEngine;
    StableAMMEngine public stableEngine;
    SupaRouter public router;
    SupaQuoter public quoter;
    QuoterLiquidityHelper public lpHelper;

    MockQuoterToken public rawTokenA;
    MockQuoterToken public rawTokenB;
    MockQuoterToken public rawTokenC;

    Currency public tokenA;
    Currency public tokenB;
    Currency public tokenC;

    PoolKey public poolAB;
    PoolKey public poolBC;

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() public {
        vault = new SupaVault(address(this));
        clammEngine = new CLAMMEngine();
        binEngine = new BinAMMEngine();
        stableEngine = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clammEngine, binEngine, stableEngine);
        vault.setPoolManager(address(manager), true);

        router = new SupaRouter(manager, vault);
        quoter = new SupaQuoter(manager, vault);
        lpHelper = new QuoterLiquidityHelper(vault, manager);

        MockQuoterToken t1 = new MockQuoterToken("Token 1", "TK1");
        MockQuoterToken t2 = new MockQuoterToken("Token 2", "TK2");
        MockQuoterToken t3 = new MockQuoterToken("Token 3", "TK3");

        address a1 = address(t1);
        address a2 = address(t2);
        address a3 = address(t3);

        if (a1 > a2) (a1, a2) = (a2, a1);
        if (a2 > a3) (a2, a3) = (a3, a2);
        if (a1 > a2) (a1, a2) = (a2, a1);

        rawTokenA = MockQuoterToken(a1);
        rawTokenB = MockQuoterToken(a2);
        rawTokenC = MockQuoterToken(a3);

        tokenA = Currency.wrap(a1);
        tokenB = Currency.wrap(a2);
        tokenC = Currency.wrap(a3);

        rawTokenA.mint(address(this), 1_000_000 ether);
        rawTokenB.mint(address(this), 1_000_000 ether);
        rawTokenC.mint(address(this), 1_000_000 ether);

        rawTokenA.mint(address(lpHelper), 1_000_000 ether);
        rawTokenB.mint(address(lpHelper), 1_000_000 ether);
        rawTokenC.mint(address(lpHelper), 1_000_000 ether);

        rawTokenA.approve(address(router), type(uint256).max);
        rawTokenB.approve(address(router), type(uint256).max);
        rawTokenC.approve(address(router), type(uint256).max);

        poolAB = PoolKey({
            currency0: tokenA,
            currency1: tokenB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolAB, SQRT_RATIO_1_1, "");

        poolBC = PoolKey({
            currency0: tokenB,
            currency1: tokenC,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolBC, SQRT_RATIO_1_1, "");

        lpHelper.addLiquidity(poolAB, -1200, 1200, 100_000 ether);
        lpHelper.addLiquidity(poolBC, -1200, 1200, 100_000 ether);
    }

    function test_quoteExactInputSingleMatchesActualSwap() public {
        uint128 amountIn = 10 ether;

        ISupaQuoter.QuoteExactInputSingleParams memory qParams = ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: poolAB, zeroForOne: true, amountIn: amountIn, sqrtPriceLimitX96: 0, hookData: ""
        });

        // Query quote
        (uint256 quotedAmountOut, uint160 quotedPrice, int24 quotedTick) = quoter.quoteExactInputSingle(qParams);
        assertTrue(quotedAmountOut > 0);

        // Execute actual swap on router
        ISupaRouter.ExactInputSingleParams memory sParams = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 actualAmountOut = router.exactInputSingle(sParams);

        // Quoted output must match actual output to the exact wei
        assertEq(quotedAmountOut, actualAmountOut, "Quoted output does not match actual swap output");

        // Pool manager slot0 after swap must match quoted slot0
        assertEq(manager.getSlot0(poolAB.toId()).sqrtPriceX96(), quotedPrice);
        assertEq(manager.getSlot0(poolAB.toId()).tick(), quotedTick);
    }

    function test_quoteExactOutputSingleMatchesActualSwap() public {
        uint128 amountOut = 5 ether;

        ISupaQuoter.QuoteExactOutputSingleParams memory qParams = ISupaQuoter.QuoteExactOutputSingleParams({
            poolKey: poolAB, zeroForOne: true, amountOut: amountOut, sqrtPriceLimitX96: 0, hookData: ""
        });

        (uint256 quotedAmountIn,,) = quoter.quoteExactOutputSingle(qParams);
        assertTrue(quotedAmountIn > 0);

        ISupaRouter.ExactOutputSingleParams memory sParams = ISupaRouter.ExactOutputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountOut: amountOut,
            amountInMaximum: type(uint128).max,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 actualAmountIn = router.exactOutputSingle(sParams);
        assertEq(quotedAmountIn, actualAmountIn, "Quoted input does not match actual input");
    }

    function test_quoterLeavesZeroStateChange() public {
        uint256 resA = vault.reservesOf(tokenA);
        uint256 resB = vault.reservesOf(tokenB);

        ISupaQuoter.QuoteExactInputSingleParams memory qParams = ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: poolAB, zeroForOne: true, amountIn: 25 ether, sqrtPriceLimitX96: 0, hookData: ""
        });

        quoter.quoteExactInputSingle(qParams);

        // Reserves must be completely unchanged
        assertEq(vault.reservesOf(tokenA), resA);
        assertEq(vault.reservesOf(tokenB), resB);
        assertFalse(vault.isUnlocked());
    }
}
