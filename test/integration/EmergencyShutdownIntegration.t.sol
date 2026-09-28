// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {BinAMMEngine} from "../../contract/core/engines/BinAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {CircuitBreaker} from "../../contract/security/CircuitBreaker.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {CircuitBreakerErrors} from "../../contract/errors/CircuitBreakerErrors.sol";

contract MockERC20 {
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

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
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

contract EmergencyShutdownIntegrationTest is Test {
    SupaVault public vault;
    SupaPoolManager public manager;
    SupaRouter public router;
    CircuitBreaker public circuitBreaker;
    SupaTimelock public timelock;

    CLAMMEngine public clamm;
    BinAMMEngine public bin;
    StableAMMEngine public stable;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;

    Currency public currA;
    Currency public currB;
    Currency public currC;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolId public clammId;
    PoolId public binId;

    address public admin = address(0xAAAA);
    address public guardian = address(0xBBBB);
    address public alice = address(0xCCCC);

    uint160 public constant SQRT_RATIO_1_1 = 79228162514264337593543950336;

    function setUp() external {
        MockERC20 t1 = new MockERC20("Token 1", "TK1");
        MockERC20 t2 = new MockERC20("Token 2", "TK2");
        MockERC20 t3 = new MockERC20("Token 3", "TK3");

        // Sort currencies deterministically
        address[3] memory tokens = [address(t1), address(t2), address(t3)];
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (tokens[i] > tokens[j]) {
                    address temp = tokens[i];
                    tokens[i] = tokens[j];
                    tokens[j] = temp;
                }
            }
        }

        tokenA = MockERC20(tokens[0]);
        tokenB = MockERC20(tokens[1]);
        tokenC = MockERC20(tokens[2]);

        currA = Currency.wrap(address(tokenA));
        currB = Currency.wrap(address(tokenB));
        currC = Currency.wrap(address(tokenC));

        // Deploy Timelock and CircuitBreaker
        address[] memory proposers = new address[](1);
        proposers[0] = admin;
        address[] memory executors = new address[](1);
        executors[0] = admin;
        address[] memory cancellers = new address[](1);
        cancellers[0] = admin;

        timelock = new SupaTimelock(1 days, admin, proposers, executors, cancellers);

        address[] memory guardians = new address[](1);
        guardians[0] = guardian;
        circuitBreaker = new CircuitBreaker(address(timelock), guardians);

        // Deploy Vault & Core
        vault = new SupaVault(address(this));
        clamm = new CLAMMEngine();
        bin = new BinAMMEngine();
        stable = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, bin, stable);
        vault.setPoolManager(address(manager), true);

        // Configure Circuit Breaker on Vault & Manager
        vault.setCircuitBreaker(circuitBreaker);
        manager.setCircuitBreaker(circuitBreaker);

        // Deploy Periphery Router
        router = new SupaRouter(manager, vault);
        vault.setPoolManager(address(router), true);

        // Initialize CLAMM Pool (A/B)
        clammKey = PoolKey({
            currency0: currA,
            currency1: currB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        clammId = clammKey.toId();
        manager.initialize(clammKey, SQRT_RATIO_1_1, "");

        // Initialize BinAMM Pool (B/C)
        binKey = PoolKey({
            currency0: currB,
            currency1: currC,
            fee: 1000,
            tickSpacing: 10,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });
        binId = binKey.toId();
        manager.initialize(binKey, SQRT_RATIO_1_1, "");

        // Mint liquidity tokens to Alice
        tokenA.mint(alice, 1000 ether);
        tokenB.mint(alice, 1000 ether);
        tokenC.mint(alice, 1000 ether);

        vm.startPrank(alice);
        tokenA.approve(address(router), type(uint256).max);
        tokenB.approve(address(router), type(uint256).max);
        tokenC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function test_emergencyPoolPauseAndRecovery() public {
        // Step 1: Guardian identifies anomaly and triggers emergency pause on CLAMM pool only
        vm.prank(guardian);
        circuitBreaker.pausePool(clammId);
        assertTrue(circuitBreaker.isPoolPaused(clammId));
        assertFalse(circuitBreaker.isPoolPaused(binId));

        // Step 2: Swap on paused CLAMM pool reverts
        vm.startPrank(alice);
        ISupaRouter.ExactInputSingleParams memory paramsCLAMM = ISupaRouter.ExactInputSingleParams({
            poolKey: clammKey,
            zeroForOne: true,
            recipient: alice,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        vm.expectRevert(CircuitBreakerErrors.PoolPaused.selector);
        router.exactInputSingle(paramsCLAMM);
        vm.stopPrank();

        // Step 3: Timelock schedules and executes unpause after investigation
        bytes memory unpauseData = abi.encodeWithSelector(CircuitBreaker.unpausePool.selector, clammId);
        bytes32 salt = bytes32(uint256(100));

        vm.prank(admin);
        timelock.schedule(address(circuitBreaker), 0, unpauseData, bytes32(0), salt, 1 days);

        vm.warp(block.timestamp + 1 days);

        vm.prank(admin);
        timelock.execute(address(circuitBreaker), 0, unpauseData, bytes32(0), salt);

        assertFalse(circuitBreaker.isPoolPaused(clammId));
    }

    function test_emergencyGlobalVaultPause() public {
        // Guardian triggers full vault emergency shutdown
        vm.prank(guardian);
        circuitBreaker.pauseVault();
        assertTrue(circuitBreaker.isVaultPaused());

        // Any router / vault interaction reverts with VaultPaused
        vm.startPrank(alice);
        ISupaRouter.ExactInputSingleParams memory params = ISupaRouter.ExactInputSingleParams({
            poolKey: binKey,
            zeroForOne: true,
            recipient: alice,
            amountIn: 1 ether,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        vm.expectRevert(CircuitBreakerErrors.VaultPaused.selector);
        router.exactInputSingle(params);
        vm.stopPrank();
    }
}
