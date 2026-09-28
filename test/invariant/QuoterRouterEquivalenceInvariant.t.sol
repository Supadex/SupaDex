// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
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
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract MockQuoterInvToken {
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

contract QuoterHelperLP is IUnlockCallback {
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
            tickLower: -120,
            tickUpper: 120,
            liquidityDelta: int256(amount),
            salt: bytes32(0)
        });

        (BalanceDelta delta, ) = manager.modifyLiquidity(key, params, "");
        if (delta.amount0() > 0) {
            MockQuoterInvToken(Currency.unwrap(key.currency0)).transfer(address(vault), uint128(delta.amount0()));
            vault.settle(key.currency0);
        }
        if (delta.amount1() > 0) {
            MockQuoterInvToken(Currency.unwrap(key.currency1)).transfer(address(vault), uint128(delta.amount1()));
            vault.settle(key.currency1);
        }
        return "";
    }
}

contract QuoterRouterEquivalenceHandler is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    SupaRouter public router;
    SupaQuoter public quoter;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockQuoterInvToken public tokenA;
    MockQuoterInvToken public tokenB;
    MockQuoterInvToken public tokenC;

    uint256 public totalEquivalentQuotes;

    constructor(
        SupaVault _vault,
        SupaPoolManager _manager,
        SupaRouter _router,
        SupaQuoter _quoter,
        PoolKey memory _clammKey,
        PoolKey memory _binKey,
        PoolKey memory _stableKey,
        MockQuoterInvToken _tokenA,
        MockQuoterInvToken _tokenB,
        MockQuoterInvToken _tokenC
    ) {
        vault = _vault;
        manager = _manager;
        router = _router;
        quoter = _quoter;
        clammKey = _clammKey;
        binKey = _binKey;
        stableKey = _stableKey;
        tokenA = _tokenA;
        tokenB = _tokenB;
        tokenC = _tokenC;
    }

    function verifyExactInputSingleCLAMM(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1_000, 10_000 ether);

        ISupaQuoter.QuoteExactInputSingleParams memory qParams = ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: clammKey,
            zeroForOne: zeroForOne,
            amountIn: uint128(amountIn),
            sqrtPriceLimitX96: 0,
            hookData: ""
        });

        (uint256 quotedAmountOut, , ) = quoter.quoteExactInputSingle(qParams);

        address swapper = address(0x4444);
        if (zeroForOne) {
            tokenA.mint(swapper, amountIn * 2);
            vm.startPrank(swapper);
            tokenA.approve(address(router), type(uint256).max);
        } else {
            tokenB.mint(swapper, amountIn * 2);
            vm.startPrank(swapper);
            tokenB.approve(address(router), type(uint256).max);
        }

        ISupaRouter.ExactInputSingleParams memory rParams = ISupaRouter.ExactInputSingleParams({
            poolKey: clammKey,
            zeroForOne: zeroForOne,
            recipient: swapper,
            amountIn: uint128(amountIn),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 actualAmountOut = router.exactInputSingle(rParams);
        vm.stopPrank();

        assertEq(quotedAmountOut, actualAmountOut, "Quoted amountOut must match executed amountOut");
        totalEquivalentQuotes++;
    }

    function verifyExactInputSingleBinAMM(bool zeroForOne, uint256 amountIn) external {
        amountIn = bound(amountIn, 1_000, 10_000 ether);

        ISupaQuoter.QuoteExactInputSingleParams memory qParams = ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: binKey,
            zeroForOne: zeroForOne,
            amountIn: uint128(amountIn),
            sqrtPriceLimitX96: 0,
            hookData: ""
        });

        (uint256 quotedAmountOut, , ) = quoter.quoteExactInputSingle(qParams);

        address swapper = address(0x5555);
        if (zeroForOne) {
            tokenB.mint(swapper, amountIn * 2);
            vm.startPrank(swapper);
            tokenB.approve(address(router), type(uint256).max);
        } else {
            tokenC.mint(swapper, amountIn * 2);
            vm.startPrank(swapper);
            tokenC.approve(address(router), type(uint256).max);
        }

        ISupaRouter.ExactInputSingleParams memory rParams = ISupaRouter.ExactInputSingleParams({
            poolKey: binKey,
            zeroForOne: zeroForOne,
            recipient: swapper,
            amountIn: uint128(amountIn),
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 100
        });

        uint256 actualAmountOut = router.exactInputSingle(rParams);
        vm.stopPrank();

        assertEq(quotedAmountOut, actualAmountOut, "BinAMM quote must match swap execution");
        totalEquivalentQuotes++;
    }
}

contract QuoterRouterEquivalenceInvariantTest is StdInvariant, Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    SupaVault public vault;
    SupaPoolManager public manager;
    SupaRouter public router;
    SupaQuoter public quoter;
    QuoterRouterEquivalenceHandler public handler;

    PoolKey public clammKey;
    PoolKey public binKey;
    PoolKey public stableKey;

    MockQuoterInvToken public tokenA;
    MockQuoterInvToken public tokenB;
    MockQuoterInvToken public tokenC;

    function setUp() public {
        vault = new SupaVault(address(this));
        CLAMMEngine clamm = new CLAMMEngine();
        BinAMMEngine binAmm = new BinAMMEngine();
        StableAMMEngine stableAmm = new StableAMMEngine();

        manager = new SupaPoolManager(vault, clamm, binAmm, stableAmm);
        vault.setPoolManager(address(manager), true);

        router = new SupaRouter(manager, vault);
        quoter = new SupaQuoter(manager, vault);

        MockQuoterInvToken[3] memory rawTokens;
        rawTokens[0] = new MockQuoterInvToken("Token A", "TKNA");
        rawTokens[1] = new MockQuoterInvToken("Token B", "TKNB");
        rawTokens[2] = new MockQuoterInvToken("Token C", "TKNC");

        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(rawTokens[i]) > address(rawTokens[j])) {
                    MockQuoterInvToken temp = rawTokens[i];
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
            currency0: cA,
            currency1: cB,
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });

        binKey = PoolKey({
            currency0: cB,
            currency1: cC,
            fee: 2000,
            tickSpacing: 10,
            plugin: address(0),
            curveType: CurveType.BIN_AMM
        });

        stableKey = PoolKey({
            currency0: cA,
            currency1: cC,
            fee: 500,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });

        manager.initialize(clammKey, 1 << 96, "");
        manager.initialize(binKey, 1 << 96, "");
        manager.initialize(stableKey, 1 << 96, "");

        QuoterHelperLP helper = new QuoterHelperLP(vault, manager);

        tokenA.mint(address(helper), 10_000_000 ether);
        tokenB.mint(address(helper), 10_000_000 ether);
        tokenC.mint(address(helper), 10_000_000 ether);

        helper.addLiquidity(clammKey, 1_000_000 ether);
        helper.addLiquidity(binKey, 1_000_000 ether);
        helper.addLiquidity(stableKey, 1_000_000 ether);

        handler = new QuoterRouterEquivalenceHandler(
            vault,
            manager,
            router,
            quoter,
            clammKey,
            binKey,
            stableKey,
            tokenA,
            tokenB,
            tokenC
        );

        targetContract(address(handler));
    }

    /// @notice Invariant: Quoter and Router must never leave transient deltas or active lock open.
    function invariant_zeroTransientDeltas() public view {
        assertFalse(vault.isUnlocked());
        assertEq(vault.getCurrencyDelta(address(quoter), clammKey.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(quoter), clammKey.currency1), 0);
        assertEq(vault.getCurrencyDelta(address(router), clammKey.currency0), 0);
        assertEq(vault.getCurrencyDelta(address(router), clammKey.currency1), 0);
    }
}
