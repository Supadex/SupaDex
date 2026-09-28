// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {IVolatilityTWAPOracle} from "../../contract/interfaces/IVolatilityTWAPOracle.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract MockBenchmarkToken {
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

contract BenchmarkLiquidityHelper is IUnlockCallback {
    SupaVault public vault;
    SupaPoolManager public manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function addLiquidity(PoolKey memory key, uint256 amount) external {
        vault.unlock(abi.encode(key, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));
        IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
            tickLower: -120, tickUpper: 120, liquidityDelta: int256(amount), salt: bytes32(0)
        });

        (BalanceDelta delta,) = manager.modifyLiquidity(key, params, "");
        if (delta.amount0() > 0) {
            MockBenchmarkToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
            vault.settle(key.currency0);
        }
        if (delta.amount1() > 0) {
            MockBenchmarkToken(Currency.unwrap(key.currency1)).transfer(address(vault), uint128(delta.amount1()));
            vault.settle(key.currency1);
        }
        return "";
    }
}

contract ClaimUnlocker is IUnlockCallback {
    SupaVault public vault;

    constructor(SupaVault _vault) {
        vault = _vault;
    }

    function execute(Currency currency, uint256 amount) external {
        vault.unlock(abi.encode(currency, amount));
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.mint(currency, address(this), amount);
        vault.burn(currency, amount);
        return "";
    }
}

contract GasBenchmarkTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    SupaRouter public router;
    SupaPositionManager public posManager;
    LVRShieldPlugin public lvrPlugin;
    VolatilityTWAPOracle public oracle;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;
    PoolKey public lvrKey;

    MockBenchmarkToken public tokenA;
    MockBenchmarkToken public tokenB;
    MockBenchmarkToken public tokenC;

    address public user = address(0x9999);

    function setUp() public {
        vault = new SupaVault(address(this));
        CLAMMEngine clamm = new CLAMMEngine();
        BinAMMEngine binAmm = new BinAMMEngine();
        StableAMMEngine stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        router = new SupaRouter(manager, vault);
        posManager = new SupaPositionManager(manager, vault);

        oracle = new VolatilityTWAPOracle();
        lvrPlugin = new LVRShieldPlugin(IPoolManager(address(manager)), IVolatilityTWAPOracle(address(oracle)));

        MockBenchmarkToken[3] memory rawTokens;
        rawTokens[0] = new MockBenchmarkToken("Token A", "TKNA");
        rawTokens[1] = new MockBenchmarkToken("Token B", "TKNB");
        rawTokens[2] = new MockBenchmarkToken("Token C", "TKNC");

        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(rawTokens[i]) > address(rawTokens[j])) {
                    MockBenchmarkToken temp = rawTokens[i];
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

        clammKey = PoolKey({
            currency0: cA, currency1: cB, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
        });

        binKey = PoolKey({
            currency0: cB, currency1: cC, fee: 2000, tickSpacing: 10, plugin: address(0), curveType: CurveType.BIN_AMM
        });

        stableKey = PoolKey({
            currency0: cA, currency1: cC, fee: 500, tickSpacing: 1, plugin: address(0), curveType: CurveType.STABLE_AMM
        });

        lvrKey = PoolKey({
            currency0: cA,
            currency1: cB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(lvrPlugin),
            curveType: CurveType.CLAMM
        });

        manager.initialize(clammKey, 1 << 96, "");
        manager.initialize(binKey, 1 << 96, "");
        manager.initialize(stableKey, 1 << 96, "");
        manager.initialize(lvrKey, 1 << 96, "");

        BenchmarkLiquidityHelper helper = new BenchmarkLiquidityHelper(vault, manager);
        tokenA.mint(address(helper), 10_000_000 ether);
        tokenB.mint(address(helper), 10_000_000 ether);
        tokenC.mint(address(helper), 10_000_000 ether);

        helper.addLiquidity(clammKey, 1_000_000 ether);
        helper.addLiquidity(binKey, 1_000_000 ether);
        helper.addLiquidity(stableKey, 1_000_000 ether);
        helper.addLiquidity(lvrKey, 1_000_000 ether);

        tokenA.mint(user, 1_000_000 ether);
        tokenB.mint(user, 1_000_000 ether);
        tokenC.mint(user, 1_000_000 ether);

        vm.startPrank(user);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        tokenA.approve(address(posManager), type(uint256).max);
        tokenB.approve(address(posManager), type(uint256).max);
        tokenC.approve(address(posManager), type(uint256).max);
        vm.stopPrank();
    }

    /// @notice Gas Benchmark: Single-hop CLAMM swap.
    function test_benchmark_clammSwapSingleHop() public {
        vm.prank(user);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: clammKey,
            zeroForOne: true,
            recipient: user,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        router.exactInputSingle(params);
    }

    /// @notice Gas Benchmark: Single-hop BinAMM swap.
    function test_benchmark_binAmmSwapSingleHop() public {
        vm.prank(user);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: binKey,
            zeroForOne: true,
            recipient: user,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        router.exactInputSingle(params);
    }

    /// @notice Gas Benchmark: Single-hop StableAMM swap.
    function test_benchmark_stableAmmSwapSingleHop() public {
        vm.prank(user);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: stableKey,
            zeroForOne: true,
            recipient: user,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        router.exactInputSingle(params);
    }

    /// @notice Gas Benchmark: Multi-hop 2-pool swap (CLAMM -> BinAMM).
    function test_benchmark_multiHopSwap() public {
        bytes memory path = abi.encodePacked(
            Currency.unwrap(clammKey.currency0),
            clammKey.fee,
            clammKey.tickSpacing,
            clammKey.plugin,
            uint8(clammKey.curveType),
            Currency.unwrap(binKey.currency0),
            binKey.fee,
            binKey.tickSpacing,
            binKey.plugin,
            uint8(binKey.curveType),
            Currency.unwrap(binKey.currency1)
        );

        vm.prank(user);
        ISupaRouter.ExactInputParams memory params = ISupaRouter.ExactInputParams({
            path: path,
            recipient: user,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        router.exactInput(params);
    }

    /// @notice Gas Benchmark: Dynamic LVR Shield fee swap with volatility updates.
    function test_benchmark_lvrDynamicFeeSwap() public {
        vm.prank(user);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: lvrKey,
            zeroForOne: true,
            recipient: user,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });
        router.exactInputSingle(params);
    }

    /// @notice Gas Benchmark: ERC-6909 transient claim mint and burn.
    function test_benchmark_claimMintAndBurn() public {
        ClaimUnlocker unlocker = new ClaimUnlocker(vault);
        unlocker.execute(clammKey.currency0, 100 ether);
    }

    /// @notice Gas Benchmark: Position NFT mint.
    function test_benchmark_positionNFTMint() public {
        vm.prank(user);
        ISupaPositionManager.MintParams memory params = ISupaPositionManager.MintParams({
            poolKey: clammKey,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 10_000 ether,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            recipient: user,
            deadline: block.timestamp + 100,
            hookData: ""
        });
        posManager.mint(params);
    }
}
