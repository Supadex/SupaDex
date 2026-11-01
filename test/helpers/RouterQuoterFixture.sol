// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {SupaQuoter} from "../../contract/periphery/SupaQuoter.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {ISupaQuoter} from "../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {SecurityTestSetup} from "./SecurityTestSetup.sol";

/// @dev Plain 18-decimal ERC20 used by the router / quoter coverage suites.
contract RQToken {
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
        require(balanceOf[msg.sender] >= amount, "RQToken: balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "RQToken: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "RQToken: balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev LP helper that supports ERC20 and native ETH legs for every curve type.
contract RQLiquidityHelper is IUnlockCallback {
    SupaVault public immutable vault;
    SupaPoolManager public immutable manager;

    constructor(SupaVault _vault, SupaPoolManager _manager) {
        vault = _vault;
        manager = _manager;
    }

    function addLiquidity(PoolKey memory key, uint256 amount) external {
        vault.unlock(abi.encode(key, SecurityTestSetup.liquidityParams(key, amount, true)));
    }

    function addLiquidityRange(PoolKey memory key, int24 lower, int24 upper, uint256 liquidity) external {
        vault.unlock(
            abi.encode(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: lower, tickUpper: upper, liquidityDelta: int256(liquidity), salt: bytes32(0)
                })
            )
        );
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "RQLiquidityHelper: vault only");
        (PoolKey memory key, IPoolManager.ModifyLiquidityParams memory p) =
            abi.decode(data, (PoolKey, IPoolManager.ModifyLiquidityParams));
        (BalanceDelta delta,) = manager.modifyLiquidity(key, p, "");
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 owed) internal {
        if (owed <= 0) return;
        uint256 amount = uint256(uint128(owed));
        if (CurrencyLibrary.isNative(currency)) {
            vault.settle{value: amount}(currency);
        } else {
            vault.sync(currency);
            RQToken(Currency.unwrap(currency)).transfer(address(vault), amount);
            vault.settle(currency);
        }
    }

    receive() external payable {}
}

/**
 * @title RouterQuoterFixture
 * @notice Shared deployment for the router / quoter coverage suites: one pool per engine plus native-ETH pools.
 *         tokenA < tokenB < tokenC (sorted), so every pool key below is in canonical order.
 *  - clammAB   CLAMM  A/B  fee 3000 ts 60
 *  - binBC     BIN    B/C  fee 2000 binStep 10
 *  - stableAC  STABLE A/C  fee 500  A = 100
 *  - clammEthA CLAMM  ETH/A
 *  - binEthB   BIN    ETH/B
 */
abstract contract RouterQuoterFixture is Test {
    using CurrencyLibrary for Currency;

    uint160 internal constant SQRT_1_1 = 1 << 96;
    uint256 internal constant LIQ = 1_000_000 ether;
    uint256 internal constant ETH_LIQ = 10_000 ether;

    SupaVault internal vault;
    SupaPoolManager internal manager;
    SupaRouter internal router;
    SupaQuoter internal quoter;
    RQLiquidityHelper internal lp;

    RQToken internal rawA;
    RQToken internal rawB;
    RQToken internal rawC;
    Currency internal tokenA;
    Currency internal tokenB;
    Currency internal tokenC;
    Currency internal constant ETH = Currency.wrap(address(0));

    PoolKey internal clammAB;
    PoolKey internal binBC;
    PoolKey internal stableAC;
    PoolKey internal clammEthA;
    PoolKey internal binEthB;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));

        router = new SupaRouter(manager, vault);
        quoter = new SupaQuoter(manager, vault);
        lp = new RQLiquidityHelper(vault, manager);

        RQToken[3] memory t;
        t[0] = new RQToken("Token A", "TKA");
        t[1] = new RQToken("Token B", "TKB");
        t[2] = new RQToken("Token C", "TKC");
        for (uint256 i = 0; i < 3; i++) {
            for (uint256 j = i + 1; j < 3; j++) {
                if (address(t[i]) > address(t[j])) (t[i], t[j]) = (t[j], t[i]);
            }
        }
        (rawA, rawB, rawC) = (t[0], t[1], t[2]);
        tokenA = Currency.wrap(address(rawA));
        tokenB = Currency.wrap(address(rawB));
        tokenC = Currency.wrap(address(rawC));

        clammAB = _key(tokenA, tokenB, 3000, 60, CurveType.CLAMM);
        binBC = _key(tokenB, tokenC, 2000, 10, CurveType.BIN_AMM);
        stableAC = _key(tokenA, tokenC, 500, 1, CurveType.STABLE_AMM);
        clammEthA = _key(ETH, tokenA, 3000, 60, CurveType.CLAMM);
        binEthB = _key(ETH, tokenB, 2000, 10, CurveType.BIN_AMM);

        manager.initialize(clammAB, SQRT_1_1, "");
        manager.initialize(binBC, SQRT_1_1, "");
        manager.initializeWithParams(stableAC, SQRT_1_1, abi.encode(uint256(100)), "");
        manager.initialize(clammEthA, SQRT_1_1, "");
        manager.initialize(binEthB, SQRT_1_1, "");

        rawA.mint(address(lp), 100 * LIQ);
        rawB.mint(address(lp), 100 * LIQ);
        rawC.mint(address(lp), 100 * LIQ);
        vm.deal(address(lp), 100 * ETH_LIQ);

        lp.addLiquidity(clammAB, LIQ);
        lp.addLiquidity(binBC, LIQ);
        lp.addLiquidity(stableAC, LIQ);
        lp.addLiquidity(clammEthA, ETH_LIQ);
        lp.addLiquidity(binEthB, ETH_LIQ);

        _fund(alice);
        _fund(bob);
    }

    function _fund(address who) internal {
        rawA.mint(who, 100_000 ether);
        rawB.mint(who, 100_000 ether);
        rawC.mint(who, 100_000 ether);
        vm.deal(who, 1_000 ether);
        vm.startPrank(who);
        rawA.approve(address(router), type(uint256).max);
        rawB.approve(address(router), type(uint256).max);
        rawC.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _key(Currency c0, Currency c1, uint24 fee, int24 ts, CurveType curve)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({currency0: c0, currency1: c1, fee: fee, tickSpacing: ts, plugin: address(0), curveType: curve});
    }

    /// @dev Encodes a path `cs[0] -keys[0]-> cs[1] -keys[1]-> ... cs[n]` in PathKeyLib layout (67 + 47 * (n - 1)).
    function _path(Currency[] memory cs, PoolKey[] memory keys) internal pure returns (bytes memory p) {
        require(cs.length == keys.length + 1, "fixture: path shape");
        p = abi.encodePacked(cs[0]);
        for (uint256 i = 0; i < keys.length; i++) {
            p = bytes.concat(
                p,
                abi.encodePacked(keys[i].fee, keys[i].tickSpacing, keys[i].plugin, uint8(keys[i].curveType), cs[i + 1])
            );
        }
    }

    function _path1(Currency a, PoolKey memory k, Currency b) internal pure returns (bytes memory) {
        Currency[] memory cs = new Currency[](2);
        PoolKey[] memory ks = new PoolKey[](1);
        (cs[0], cs[1], ks[0]) = (a, b, k);
        return _path(cs, ks);
    }

    function _path2(Currency a, PoolKey memory k1, Currency b, PoolKey memory k2, Currency c)
        internal
        pure
        returns (bytes memory)
    {
        Currency[] memory cs = new Currency[](3);
        PoolKey[] memory ks = new PoolKey[](2);
        (cs[0], cs[1], cs[2], ks[0], ks[1]) = (a, b, c, k1, k2);
        return _path(cs, ks);
    }

    function _path3(
        Currency a,
        PoolKey memory k1,
        Currency b,
        PoolKey memory k2,
        Currency c,
        PoolKey memory k3,
        Currency d
    ) internal pure returns (bytes memory) {
        Currency[] memory cs = new Currency[](4);
        PoolKey[] memory ks = new PoolKey[](3);
        (cs[0], cs[1], cs[2], cs[3], ks[0], ks[1], ks[2]) = (a, b, c, d, k1, k2, k3);
        return _path(cs, ks);
    }

    function _inSingle(PoolKey memory key, bool zeroForOne, address recipient, uint128 amountIn, uint128 minOut)
        internal
        view
        returns (ISupaRouter.ExactInputSingleParams memory)
    {
        return ISupaRouter.ExactInputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 1 hours
        });
    }

    function _outSingle(PoolKey memory key, bool zeroForOne, address recipient, uint128 amountOut, uint128 maxIn)
        internal
        view
        returns (ISupaRouter.ExactOutputSingleParams memory)
    {
        return ISupaRouter.ExactOutputSingleParams({
            poolKey: key,
            zeroForOne: zeroForOne,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: maxIn,
            sqrtPriceLimitX96: 0,
            hookData: "",
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 1 hours
        });
    }

    function _inMulti(bytes memory path, address recipient, uint128 amountIn, uint128 minOut)
        internal
        view
        returns (ISupaRouter.ExactInputParams memory)
    {
        return ISupaRouter.ExactInputParams({
            path: path,
            recipient: recipient,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 1 hours
        });
    }

    function _outMulti(bytes memory path, address recipient, uint128 amountOut, uint128 maxIn)
        internal
        view
        returns (ISupaRouter.ExactOutputParams memory)
    {
        return ISupaRouter.ExactOutputParams({
            path: path,
            recipient: recipient,
            amountOut: amountOut,
            amountInMaximum: maxIn,
            payWithClaims: false,
            receiveAsClaims: false,
            deadline: block.timestamp + 1 hours
        });
    }

    function _qIn(PoolKey memory key, bool zeroForOne, uint128 amountIn)
        internal
        pure
        returns (ISupaQuoter.QuoteExactInputSingleParams memory)
    {
        return ISupaQuoter.QuoteExactInputSingleParams({
            poolKey: key, zeroForOne: zeroForOne, amountIn: amountIn, sqrtPriceLimitX96: 0, hookData: ""
        });
    }

    function _qOut(PoolKey memory key, bool zeroForOne, uint128 amountOut)
        internal
        pure
        returns (ISupaQuoter.QuoteExactOutputSingleParams memory)
    {
        return ISupaQuoter.QuoteExactOutputSingleParams({
            poolKey: key, zeroForOne: zeroForOne, amountOut: amountOut, sqrtPriceLimitX96: 0, hookData: ""
        });
    }

    /// @dev Balance of `who` in `c` (native ETH or an RQToken).
    function _bal(Currency c, address who) internal view returns (uint256) {
        if (c.isNative()) return who.balance;
        return RQToken(Currency.unwrap(c)).balanceOf(who);
    }

    function _keyIn(PoolKey memory key, bool zeroForOne) internal pure returns (Currency) {
        return zeroForOne ? key.currency0 : key.currency1;
    }

    function _keyOut(PoolKey memory key, bool zeroForOne) internal pure returns (Currency) {
        return zeroForOne ? key.currency1 : key.currency0;
    }

    /// @dev Router and quoter must never leave a non-zero transient delta or an open lock behind.
    function _assertClean() internal view {
        assertFalse(vault.isUnlocked(), "vault left unlocked");
        Currency[4] memory cs = [ETH, tokenA, tokenB, tokenC];
        for (uint256 i = 0; i < 4; i++) {
            assertEq(vault.getCurrencyDelta(address(router), cs[i]), 0, "router delta");
            assertEq(vault.getCurrencyDelta(address(quoter), cs[i]), 0, "quoter delta");
        }
        assertEq(address(router).balance, 0, "router holds ETH");
        assertEq(rawA.balanceOf(address(router)), 0, "router holds A");
        assertEq(rawB.balanceOf(address(router)), 0, "router holds B");
        assertEq(rawC.balanceOf(address(router)), 0, "router holds C");
    }
}
