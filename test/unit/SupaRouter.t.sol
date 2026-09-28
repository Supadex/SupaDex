// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";
import {PathKeyLib} from "../../contract/periphery/libraries/PathKeyLib.sol";

contract MockRouterToken {
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

contract LiquidityProviderHelper is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function addLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) external payable {
        vault.unlock(abi.encode(key, tickLower, tickUpper, liquidity));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(data, (PoolKey, int24, int24, uint128));

        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidityDelta: int256(uint256(liquidity)),
            salt: bytes32(0)
        });

        (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");

        if (delta.amount0() > 0) {
            uint256 amount0 = uint256(uint128(delta.amount0()));
            if (key.currency0.isNative()) {
                vault.settle{value: amount0}(key.currency0);
            } else {
                MockRouterToken(Currency.unwrap(key.currency0)).transfer(address(vault), amount0);
                vault.settle(key.currency0);
            }
        }
        if (delta.amount1() > 0) {
            uint256 amount1 = uint256(uint128(delta.amount1()));
            if (key.currency1.isNative()) {
                vault.settle{value: amount1}(key.currency1);
            } else {
                MockRouterToken(Currency.unwrap(key.currency1)).transfer(address(vault), amount1);
                vault.settle(key.currency1);
            }
        }

        return "";
    }

    receive() external payable {}
}

contract SupaRouterTest is Test {
    using PathKeyLib for bytes;
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    CLAMMEngine public clammEngine;
    BinAMMEngine public binEngine;
    StableAMMEngine public stableEngine;
    SupaRouter public router;
    LiquidityProviderHelper public lpHelper;

    MockRouterToken public rawTokenA;
    MockRouterToken public rawTokenB;
    MockRouterToken public rawTokenC;

    Currency public tokenA;
    Currency public tokenB;
    Currency public tokenC;
    Currency public nativeETH;

    PoolKey public poolAB;
    PoolKey public poolBC;
    PoolKey public poolEthA;

    uint160 constant SQRT_RATIO_1_1 = 79228162514264337593543950336; // 1.0 in Q64.96

    function setUp() public {
        vault = new SupaVault(address(this));
        clammEngine = new CLAMMEngine();
        binEngine = new BinAMMEngine();
        stableEngine = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clammEngine, binEngine, stableEngine);
        vault.setPoolManager(address(manager), true);

        router = new SupaRouter(manager, vault);
        lpHelper = new LiquidityProviderHelper(vault, manager);

        // Deploy 3 sorted tokens
        MockRouterToken t1 = new MockRouterToken("Token 1", "TK1");
        MockRouterToken t2 = new MockRouterToken("Token 2", "TK2");
        MockRouterToken t3 = new MockRouterToken("Token 3", "TK3");

        address a1 = address(t1);
        address a2 = address(t2);
        address a3 = address(t3);

        // Ensure sorted: a1 < a2 < a3
        if (a1 > a2) (a1, a2) = (a2, a1);
        if (a2 > a3) (a2, a3) = (a3, a2);
        if (a1 > a2) (a1, a2) = (a2, a1);

        rawTokenA = MockRouterToken(a1);
        rawTokenB = MockRouterToken(a2);
        rawTokenC = MockRouterToken(a3);

        tokenA = Currency.wrap(a1);
        tokenB = Currency.wrap(a2);
        tokenC = Currency.wrap(a3);
        nativeETH = CurrencyLibrary.NATIVE;

        // Mint initial supply
        rawTokenA.mint(address(this), 1_000_000 ether);
        rawTokenB.mint(address(this), 1_000_000 ether);
        rawTokenC.mint(address(this), 1_000_000 ether);

        rawTokenA.mint(address(lpHelper), 1_000_000 ether);
        rawTokenB.mint(address(lpHelper), 1_000_000 ether);
        rawTokenC.mint(address(lpHelper), 1_000_000 ether);
        vm.deal(address(lpHelper), 1000 ether);

        // Approve router
        rawTokenA.approve(address(router), type(uint256).max);
        rawTokenB.approve(address(router), type(uint256).max);
        rawTokenC.approve(address(router), type(uint256).max);

        // Initialize pool AB (CLAMM)
        poolAB = PoolKey({
            currency0: tokenA,
            currency1: tokenB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolAB, SQRT_RATIO_1_1, "");

        // Initialize pool BC (CLAMM)
        poolBC = PoolKey({
            currency0: tokenB,
            currency1: tokenC,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolBC, SQRT_RATIO_1_1, "");

        // Initialize pool ETH-TokenA (CLAMM)
        poolEthA = PoolKey({
            currency0: nativeETH,
            currency1: tokenA,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(poolEthA, SQRT_RATIO_1_1, "");

        // Add deep liquidity to pools
        lpHelper.addLiquidity(poolAB, -1200, 1200, 100_000 ether);
        lpHelper.addLiquidity(poolBC, -1200, 1200, 100_000 ether);
        lpHelper.addLiquidity{value: 50 ether}(poolEthA, -1200, 1200, 50 ether);
    }

    function test_exactInputSingleCLAMM() public {
        uint256 amountIn = 10 ether;
        uint256 balanceBefore = rawTokenB.balanceOf(address(this));

        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: uint128(amountIn),
            amountOutMinimum: 9 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 amountOut = router.exactInputSingle(params);
        assertTrue(amountOut >= 9 ether, "Received less than minimum");
        assertEq(rawTokenB.balanceOf(address(this)), balanceBefore + amountOut);
    }

    function test_exactOutputSingleCLAMM() public {
        uint256 amountOut = 5 ether;
        uint256 balanceBeforeA = rawTokenA.balanceOf(address(this));
        uint256 balanceBeforeB = rawTokenB.balanceOf(address(this));

        ISupaRouter.ExactOutputSingleParams memory params = ISupaRouter.ExactOutputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountOut: uint128(amountOut),
            amountInMaximum: 6 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 amountIn = router.exactOutputSingle(params);
        assertTrue(amountIn <= 6 ether, "Spent more than max input");
        assertEq(rawTokenB.balanceOf(address(this)), balanceBeforeB + amountOut);
        assertEq(rawTokenA.balanceOf(address(this)), balanceBeforeA - amountIn);
    }

    function test_exactInputMultiHop() public {
        // Multi-hop path: TokenA -> PoolAB -> TokenB -> PoolBC -> TokenC
        bytes memory hop1 = PathKeyLib.encodeHop(
            tokenA,
            tokenB,
            poolAB.fee,
            poolAB.tickSpacing,
            poolAB.plugin,
            poolAB.curveType
        );
        bytes memory multiPath = abi.encodePacked(
            hop1,
            abi.encodePacked(
                poolBC.fee,
                poolBC.tickSpacing,
                poolBC.plugin,
                uint8(poolBC.curveType),
                tokenC
            )
        );

        uint256 amountIn = 10 ether;
        uint256 balanceBeforeC = rawTokenC.balanceOf(address(this));

        ISupaRouter.ExactInputParams memory params = ISupaRouter.ExactInputParams({
            path: multiPath,
            recipient: address(this),
            amountIn: uint128(amountIn),
            amountOutMinimum: 8 ether,
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 amountOut = router.exactInput(params);
        assertTrue(amountOut >= 8 ether, "Multi-hop output below min");
        assertEq(rawTokenC.balanceOf(address(this)), balanceBeforeC + amountOut);
    }

    function test_exactInputWithNativeETH() public {
        uint256 ethAmountIn = 1 ether;
        uint256 balanceBeforeA = rawTokenA.balanceOf(address(this));

        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: poolEthA,
            zeroForOne: true,
            recipient: address(this),
            amountIn: uint128(ethAmountIn),
            amountOutMinimum: 0.9 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 amountOut = router.exactInputSingle{value: ethAmountIn}(params);
        assertTrue(amountOut >= 0.9 ether);
        assertEq(rawTokenA.balanceOf(address(this)), balanceBeforeA + amountOut);
    }

    function test_slippageExceededReverts() public {
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: 10 ether,
            amountOutMinimum: 100 ether, // Impossible minimum
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        vm.expectRevert();
        router.exactInputSingle(params);
    }

    function test_deadlinePassedReverts() public {
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: 10 ether,
            amountOutMinimum: 1 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp - 1 // Past deadline
        });

        vm.expectRevert();
        router.exactInputSingle(params);
    }

    function test_multicallBatchSwaps() public {
        bytes[] memory calls = new bytes[](2);

        ISupaRouter.ExactInputSingleParams memory param1 = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: 1 ether,
            amountOutMinimum: 0.9 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        ISupaRouter.ExactInputSingleParams memory param2 = ISupaRouter.ExactInputSingleParams({
            poolKey: poolAB,
            zeroForOne: true,
            recipient: address(this),
            amountIn: 2 ether,
            amountOutMinimum: 1.8 ether,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        calls[0] = abi.encodeWithSelector(router.exactInputSingle.selector, param1);
        calls[1] = abi.encodeWithSelector(router.exactInputSingle.selector, param2);

        bytes[] memory results = router.multicall(calls);
        assertEq(results.length, 2);

        uint256 out1 = abi.decode(results[0], (uint256));
        uint256 out2 = abi.decode(results[1], (uint256));
        assertTrue(out1 >= 0.9 ether);
        assertTrue(out2 >= 1.8 ether);
    }

    receive() external payable {}
}
