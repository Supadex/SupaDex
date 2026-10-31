// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RouterQuoterFixture, RQToken} from "../helpers/RouterQuoterFixture.sol";
import {SupaRouter} from "../../contract/periphery/SupaRouter.sol";
import {ISupaRouter} from "../../contract/interfaces/ISupaRouter.sol";
import {IPeripheryEvents} from "../../contract/events/IPeripheryEvents.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";
import {PeripheryErrors} from "../../contract/errors/PeripheryErrors.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";
import {TickMathLib} from "../../contract/libraries/TickMathLib.sol";

/// @dev ERC20 that re-enters the router (or the vault) from inside `transferFrom` once armed. The re-entrant call's
///      outcome is recorded (not re-raised), so a test can prove WHY it failed and that the outer swap still settles.
contract ReentrantToken is RQToken {
    enum Mode {
        NONE,
        ROUTER,
        VAULT
    }

    Mode public mode;
    SupaRouter public router;
    bytes public reentryCalldata;
    bool public lastOk;
    bytes public lastRet;
    bool public attempted;

    constructor() RQToken("Reentrant", "RE") {}

    function arm(Mode m, SupaRouter r, bytes calldata data) external {
        mode = m;
        router = r;
        reentryCalldata = data;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        Mode m = mode;
        if (m != Mode.NONE) {
            mode = Mode.NONE; // one shot
            address target = m == Mode.VAULT ? address(router.vault()) : address(router);
            (lastOk, lastRet) = target.call(reentryCalldata);
            attempted = true;
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Recipient that rejects native ETH (exercises SafeTransferLib failure paths in the router).
contract ETHRejecter {
    receive() external payable {
        revert("no ETH");
    }
}

/**
 * @title SupaRouterCoverageTest
 * @notice Path-by-path coverage of SupaRouter + PeripheryPayments + Multicall across CLAMM, BIN and Stable pools.
 */
contract SupaRouterCoverageTest is RouterQuoterFixture, IPeripheryEvents {
    using CurrencyLibrary for Currency;
    using Slot0Library for Slot0;

    function _pools() internal view returns (PoolKey[5] memory) {
        return [clammAB, binBC, stableAC, clammEthA, binEthB];
    }

    // ---------------------------------------------------------------------
    //                               getters
    // ---------------------------------------------------------------------

    function test_getters() public view {
        assertEq(address(router.poolManager()), address(manager));
        assertEq(address(router.vault()), address(vault));
    }

    // ---------------------------------------------------------------------
    //                       exact input, single hop
    // ---------------------------------------------------------------------

    function _exactInSingle(PoolKey memory key, bool zfo, uint128 amountIn) internal {
        Currency cin = _keyIn(key, zfo);
        Currency cout = _keyOut(key, zfo);
        (uint256 quoted,,) = quoter.quoteExactInputSingle(_qIn(key, zfo, amountIn));
        assertGt(quoted, 0, "quote > 0");

        uint256 aliceInBefore = _bal(cin, alice);
        uint256 bobOutBefore = _bal(cout, bob);
        // Native input: overpay by 1 ether, router must refund the unused part to the payer.
        uint256 value = cin.isNative() ? uint256(amountIn) + 1 ether : 0;

        vm.prank(alice);
        uint256 out = router.exactInputSingle{value: value}(_inSingle(key, zfo, bob, amountIn, uint128(quoted)));

        assertEq(out, quoted, "out == quote");
        assertEq(_bal(cout, bob) - bobOutBefore, out, "recipient got out");
        uint256 paid = aliceInBefore - _bal(cin, alice);
        assertLe(paid, amountIn, "paid <= amountIn");
        assertGe(paid + 1, amountIn, "paid within 1 wei of amountIn (APUS-SUPADEX-025)");
        _assertClean();
    }

    function test_exactInputSingle_allEngines_bothDirections() public {
        PoolKey[5] memory ps = _pools();
        for (uint256 i = 0; i < ps.length; i++) {
            _exactInSingle(ps[i], true, 3 ether);
            _exactInSingle(ps[i], false, 2 ether);
        }
    }

    function test_exactInputSingle_emitsSwapRouted() public {
        (uint256 quoted,,) = quoter.quoteExactInputSingle(_qIn(stableAC, true, 5 ether));
        vm.expectEmit(true, true, true, true, address(router));
        emit SwapRouted(alice, bob, tokenA, tokenC, 5 ether, quoted);
        vm.prank(alice);
        router.exactInputSingle(_inSingle(stableAC, true, bob, 5 ether, 0));
    }

    function test_exactInputSingle_slippageReverts_eachEngine() public {
        PoolKey[3] memory ps = [clammAB, binBC, stableAC];
        for (uint256 i = 0; i < ps.length; i++) {
            (uint256 quoted,,) = quoter.quoteExactInputSingle(_qIn(ps[i], true, 1 ether));
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.SlippageExceeded.selector, quoted + 1, quoted));
            router.exactInputSingle(_inSingle(ps[i], true, alice, 1 ether, uint128(quoted + 1)));
        }
        _assertClean();
    }

    function test_exactInputSingle_priceLimitPartialFill_clamm() public {
        // A price limit 10 ticks below spot stops the swap early; only the consumed input is pulled.
        uint160 limit = TickMathLib.getSqrtRatioAtTick(-10);
        ISupaRouter.ExactInputSingleParams memory p = _inSingle(clammAB, true, alice, 50_000 ether, 0);
        p.sqrtPriceLimitX96 = limit;
        uint256 before = rawA.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.exactInputSingle(p);
        uint256 paid = before - rawA.balanceOf(alice);
        assertGt(out, 0);
        assertLt(paid, 50_000 ether, "partial fill pulls only consumed input");
        assertEq(manager.getSlot0(clammAB.toId()).sqrtPriceX96(), limit, "stopped at limit");
        _assertClean();
    }

    function test_exactInputSingle_priceLimitAlreadyExceeded_reverts() public {
        ISupaRouter.ExactInputSingleParams memory p = _inSingle(clammAB, true, alice, 1 ether, 0);
        p.sqrtPriceLimitX96 = SQRT_1_1 + 1; // above spot for a zeroForOne swap
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PriceLimitAlreadyExceeded.selector, SQRT_1_1, SQRT_1_1 + 1));
        router.exactInputSingle(p);
    }

    function test_exactInputSingle_zeroAmount_reverts_eachEngine() public {
        PoolKey[3] memory ps = [clammAB, binBC, stableAC];
        for (uint256 i = 0; i < ps.length; i++) {
            vm.prank(alice);
            vm.expectRevert(PoolErrors.ZeroSwapAmount.selector);
            router.exactInputSingle(_inSingle(ps[i], true, alice, 0, 0));
            vm.prank(alice);
            vm.expectRevert(PoolErrors.ZeroSwapAmount.selector);
            router.exactOutputSingle(_outSingle(ps[i], true, alice, 0, type(uint128).max));
        }
    }

    function test_uninitializedPool_reverts() public {
        PoolKey memory k = _key(tokenA, tokenB, 100, 1, CurveType.CLAMM);
        PoolId id = k.toId();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PoolNotInitialized.selector, id));
        router.exactInputSingle(_inSingle(k, true, alice, 1 ether, 0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PoolNotInitialized.selector, id));
        router.exactInput(_inMulti(_path1(tokenA, k, tokenB), alice, 1 ether, 0));
    }

    // ---------------------------------------------------------------------
    //                       exact output, single hop
    // ---------------------------------------------------------------------

    function _exactOutSingle(PoolKey memory key, bool zfo, uint128 amountOut) internal {
        Currency cin = _keyIn(key, zfo);
        Currency cout = _keyOut(key, zfo);
        (uint256 quotedIn,,) = quoter.quoteExactOutputSingle(_qOut(key, zfo, amountOut));
        assertGt(quotedIn, 0, "quote > 0");

        uint256 aliceInBefore = _bal(cin, alice);
        uint256 bobOutBefore = _bal(cout, bob);
        uint256 value = cin.isNative() ? quotedIn + 1 ether : 0;

        vm.prank(alice);
        uint256 amountIn =
            router.exactOutputSingle{value: value}(_outSingle(key, zfo, bob, amountOut, uint128(quotedIn)));

        assertEq(amountIn, quotedIn, "amountIn == quote");
        assertEq(_bal(cout, bob) - bobOutBefore, amountOut, "recipient got exact amountOut");
        assertEq(aliceInBefore - _bal(cin, alice), amountIn, "payer charged exactly amountIn (ETH excess refunded)");
        _assertClean();
    }

    function test_exactOutputSingle_allEngines_bothDirections() public {
        PoolKey[5] memory ps = _pools();
        for (uint256 i = 0; i < ps.length; i++) {
            _exactOutSingle(ps[i], true, 2 ether);
            _exactOutSingle(ps[i], false, 1 ether);
        }
    }

    function test_exactOutputSingle_maxInReverts_eachEngine() public {
        PoolKey[3] memory ps = [clammAB, binBC, stableAC];
        for (uint256 i = 0; i < ps.length; i++) {
            (uint256 quotedIn,,) = quoter.quoteExactOutputSingle(_qOut(ps[i], false, 1 ether));
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.SlippageExceeded.selector, quotedIn - 1, quotedIn));
            router.exactOutputSingle(_outSingle(ps[i], false, alice, 1 ether, uint128(quotedIn - 1)));
        }
    }

    function test_exactOutputSingle_emitsSwapRouted() public {
        (uint256 quotedIn,,) = quoter.quoteExactOutputSingle(_qOut(binBC, false, 3 ether));
        vm.expectEmit(true, true, true, true, address(router));
        emit SwapRouted(alice, bob, tokenC, tokenB, quotedIn, 3 ether);
        vm.prank(alice);
        router.exactOutputSingle(_outSingle(binBC, false, bob, 3 ether, type(uint128).max));
    }

    /// @notice FINDING CANDIDATE (reported, not fixed): exactOutputSingle does not require the received amount to
    ///         equal `amountOut`. When CLAMM liquidity runs out (sqrtPriceLimitX96 == 0) the swap fills partially
    ///         and the router delivers LESS than the requested exact output without reverting. Uniswap v3's
    ///         SwapRouter reverts in this case when no price limit is set. The payer is charged only for what was
    ///         delivered and stays bounded by amountInMaximum, so no funds are lost; it is a semantics gap.
    function test_PoC_exactOutputSingle_partialFillUnderDelivers_clamm() public {
        // Thin CLAMM pool: liquidity only in [-60, 60].
        PoolKey memory thin = _key(tokenA, tokenB, 3000, 60, CurveType.CLAMM);
        thin.fee = 10000;
        thin.tickSpacing = 200;
        manager.initialize(thin, SQRT_1_1, "");
        lp.addLiquidityRange(thin, -200, 200, 1_000 ether);

        uint128 requested = 1_000 ether; // far more token1 than the range holds
        uint256 bobBefore = rawB.balanceOf(bob);
        vm.prank(alice);
        uint256 amountIn = router.exactOutputSingle(_outSingle(thin, true, bob, requested, type(uint128).max));
        uint256 delivered = rawB.balanceOf(bob) - bobBefore;

        assertLt(delivered, requested, "PoC: router delivered less than the exact amountOut and did not revert");
        assertGt(amountIn, 0);
        _assertClean();
    }

    // ---------------------------------------------------------------------
    //                         multi-hop, exact input
    // ---------------------------------------------------------------------

    function test_exactInput_multiHop_allEngines() public {
        // A -CLAMM-> B -BIN-> C -STABLE-> A  (3 hops, three different engines)
        bytes memory path = _path3(tokenA, clammAB, tokenB, binBC, tokenC, stableAC, tokenA);
        uint256 quoted = quoter.quoteExactInput(path, 10 ether);
        uint256 bobBefore = rawA.balanceOf(bob);
        uint256 aliceBefore = rawA.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.exactInput(_inMulti(path, bob, 10 ether, uint128(quoted)));
        assertEq(out, quoted, "multi out == quote");
        assertEq(rawA.balanceOf(bob) - bobBefore, out);
        assertLe(aliceBefore - rawA.balanceOf(alice), 10 ether);
        _assertClean();
    }

    function test_exactInput_multiHop_reverseDirections() public {
        // C -STABLE-> A -CLAMM-> B (oneForZero then zeroForOne)
        bytes memory path = _path2(tokenC, stableAC, tokenA, clammAB, tokenB);
        uint256 quoted = quoter.quoteExactInput(path, 4 ether);
        vm.prank(alice);
        uint256 out = router.exactInput(_inMulti(path, alice, 4 ether, 0));
        assertEq(out, quoted);
        // B -BIN-> C -STABLE-> A
        path = _path2(tokenB, binBC, tokenC, stableAC, tokenA);
        quoted = quoter.quoteExactInput(path, 4 ether);
        vm.prank(alice);
        out = router.exactInput(_inMulti(path, alice, 4 ether, 0));
        assertEq(out, quoted);
        _assertClean();
    }

    function test_exactInput_singlePoolPath() public {
        bytes memory path = _path1(tokenB, binBC, tokenC);
        uint256 quoted = quoter.quoteExactInput(path, 1 ether);
        vm.prank(alice);
        assertEq(router.exactInput(_inMulti(path, alice, 1 ether, 0)), quoted);
        _assertClean();
    }

    function test_exactInput_nativeInAndOut_multiHop() public {
        // ETH -CLAMM-> A -CLAMM-> B -BIN-> ETH  (native in, native out, overpay refunded)
        bytes memory path = _path3(ETH, clammEthA, tokenA, clammAB, tokenB, binEthB, ETH);
        uint256 quoted = quoter.quoteExactInput(path, 1 ether);
        uint256 aliceEthBefore = alice.balance;
        uint256 bobEthBefore = bob.balance;
        vm.prank(alice);
        uint256 out = router.exactInput{value: 3 ether}(_inMulti(path, bob, 1 ether, uint128(quoted)));
        assertEq(out, quoted);
        assertEq(bob.balance - bobEthBefore, out, "native out delivered");
        uint256 paid = aliceEthBefore - alice.balance;
        assertLe(paid, 1 ether, "excess ETH refunded");
        assertGe(paid + 1, 1 ether);
        _assertClean();
    }

    function test_exactInput_slippageReverts() public {
        bytes memory path = _path2(tokenA, clammAB, tokenB, binBC, tokenC);
        uint256 quoted = quoter.quoteExactInput(path, 2 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.SlippageExceeded.selector, quoted + 1, quoted));
        router.exactInput(_inMulti(path, alice, 2 ether, uint128(quoted + 1)));
    }

    function test_exactInput_emitsSwapRouted() public {
        bytes memory path = _path2(tokenA, stableAC, tokenC, binBC, tokenB);
        uint256 quoted = quoter.quoteExactInput(path, 2 ether);
        vm.expectEmit(true, true, true, true, address(router));
        emit SwapRouted(alice, bob, tokenA, tokenB, 2 ether, quoted);
        vm.prank(alice);
        router.exactInput(_inMulti(path, bob, 2 ether, 0));
    }

    function test_exactInput_invalidPath_reverts() public {
        bytes memory shortPath = new bytes(66);
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.InvalidPath.selector);
        router.exactInput(_inMulti(shortPath, alice, 1 ether, 0));
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.InvalidPath.selector);
        router.exactInput(_inMulti("", alice, 1 ether, 0));
    }

    function test_exactInput_identicalCurrencies_reverts() public {
        bytes memory path = _path1(tokenA, clammAB, tokenA);
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.IdenticalCurrencies.selector);
        router.exactInput(_inMulti(path, alice, 1 ether, 0));
        // second hop identical
        path = _path2(tokenA, clammAB, tokenB, clammAB, tokenB);
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.IdenticalCurrencies.selector);
        router.exactInput(_inMulti(path, alice, 1 ether, 0));
    }

    function test_exactInput_zeroAmount_reverts() public {
        bytes memory path = _path2(tokenA, clammAB, tokenB, binBC, tokenC);
        vm.prank(alice);
        vm.expectRevert(PoolErrors.ZeroSwapAmount.selector);
        router.exactInput(_inMulti(path, alice, 0, 0));
    }

    function test_exactInput_unknownPoolInSecondHop_reverts() public {
        PoolKey memory missing = _key(tokenB, tokenC, 100, 1, CurveType.CLAMM);
        bytes memory path = _path2(tokenA, clammAB, tokenB, missing, tokenC);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.PoolNotInitialized.selector, missing.toId()));
        router.exactInput(_inMulti(path, alice, 1 ether, 0));
    }

    // ---------------------------------------------------------------------
    //                         multi-hop, exact output
    // ---------------------------------------------------------------------

    function test_exactOutput_multiHop_allEngines() public {
        // Exact-out paths are encoded output-first: A <-STABLE- C <-BIN- B <-CLAMM- A
        bytes memory path = _path3(tokenA, stableAC, tokenC, binBC, tokenB, clammAB, tokenA);
        uint256 quotedIn = quoter.quoteExactOutput(path, 5 ether);
        uint256 bobBefore = rawA.balanceOf(bob);
        uint256 aliceBefore = rawA.balanceOf(alice);
        vm.prank(alice);
        uint256 amountIn = router.exactOutput(_outMulti(path, bob, 5 ether, uint128(quotedIn)));
        assertEq(amountIn, quotedIn, "multi amountIn == quote");
        assertEq(rawA.balanceOf(bob) - bobBefore, 5 ether, "exact out delivered");
        assertEq(aliceBefore - rawA.balanceOf(alice), amountIn, "payer charged amountIn");
        _assertClean();
    }

    function test_exactOutput_multiHop_otherDirections() public {
        // want C, pay B via A: C <-STABLE- A <-CLAMM- B
        bytes memory path = _path2(tokenC, stableAC, tokenA, clammAB, tokenB);
        uint256 quotedIn = quoter.quoteExactOutput(path, 2 ether);
        vm.prank(alice);
        assertEq(router.exactOutput(_outMulti(path, alice, 2 ether, type(uint128).max)), quotedIn);
        // single-pool exact-out path
        path = _path1(tokenB, binBC, tokenC);
        quotedIn = quoter.quoteExactOutput(path, 2 ether);
        vm.prank(alice);
        assertEq(router.exactOutput(_outMulti(path, alice, 2 ether, type(uint128).max)), quotedIn);
        _assertClean();
    }

    function test_exactOutput_nativeInAndOut_multiHop() public {
        // want ETH, pay ETH: ETH <-BIN- B <-CLAMM- A <-CLAMM- ETH
        bytes memory path = _path3(ETH, binEthB, tokenB, clammAB, tokenA, clammEthA, ETH);
        uint256 quotedIn = quoter.quoteExactOutput(path, 0.5 ether);
        uint256 aliceBefore = alice.balance;
        uint256 bobBefore = bob.balance;
        vm.prank(alice);
        uint256 amountIn =
            router.exactOutput{value: quotedIn + 2 ether}(_outMulti(path, bob, 0.5 ether, uint128(quotedIn)));
        assertEq(amountIn, quotedIn);
        assertEq(bob.balance - bobBefore, 0.5 ether);
        assertEq(aliceBefore - alice.balance, amountIn, "excess ETH refunded");
        _assertClean();
    }

    function test_exactOutput_slippageReverts() public {
        bytes memory path = _path2(tokenC, binBC, tokenB, clammAB, tokenA);
        uint256 quotedIn = quoter.quoteExactOutput(path, 1 ether);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.SlippageExceeded.selector, quotedIn - 1, quotedIn));
        router.exactOutput(_outMulti(path, alice, 1 ether, uint128(quotedIn - 1)));
    }

    function test_exactOutput_emitsSwapRouted() public {
        bytes memory path = _path2(tokenC, binBC, tokenB, clammAB, tokenA);
        uint256 quotedIn = quoter.quoteExactOutput(path, 1 ether);
        vm.expectEmit(true, true, true, true, address(router));
        emit SwapRouted(alice, bob, tokenA, tokenC, quotedIn, 1 ether);
        vm.prank(alice);
        router.exactOutput(_outMulti(path, bob, 1 ether, type(uint128).max));
    }

    function test_exactOutput_invalidPath_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.InvalidPath.selector);
        router.exactOutput(_outMulti(new bytes(20), alice, 1 ether, type(uint128).max));
        bytes memory path = _path1(tokenB, binBC, tokenB);
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.IdenticalCurrencies.selector);
        router.exactOutput(_outMulti(path, alice, 1 ether, type(uint128).max));
    }

    function test_exactOutput_zeroAmount_reverts() public {
        bytes memory path = _path2(tokenC, binBC, tokenB, clammAB, tokenA);
        vm.prank(alice);
        vm.expectRevert(PoolErrors.ZeroSwapAmount.selector);
        router.exactOutput(_outMulti(path, alice, 0, type(uint128).max));
    }

    /// @notice Multi-hop exact-out never under-delivers silently: if the last hop cannot fill, the router takes the
    ///         requested amount anyway and the vault's settlement check reverts the whole trade (fail closed).
    function test_exactOutput_multiHop_partialFillFailsClosed() public {
        PoolKey memory thin = _key(tokenA, tokenB, 10000, 200, CurveType.CLAMM);
        manager.initialize(thin, SQRT_1_1, "");
        lp.addLiquidityRange(thin, -200, 200, 1_000 ether);
        // want B (from thin pool, can't fill 1000), pay C via BIN: B <-thin- A <-STABLE- C
        bytes memory path = _path2(tokenB, thin, tokenA, stableAC, tokenC);
        vm.prank(alice);
        vm.expectPartialRevert(VaultErrors.CurrencyNotSettled.selector);
        router.exactOutput(_outMulti(path, alice, 1_000 ether, type(uint128).max));
    }

    // ---------------------------------------------------------------------
    //                               deadline
    // ---------------------------------------------------------------------

    function test_deadline_allEntryPoints() public {
        vm.warp(1_000_000);
        uint256 past = block.timestamp - 1;
        bytes memory dl = abi.encodeWithSelector(PeripheryErrors.DeadlinePassed.selector, past, block.timestamp);

        ISupaRouter.ExactInputSingleParams memory a = _inSingle(clammAB, true, alice, 1 ether, 0);
        a.deadline = past;
        vm.prank(alice);
        vm.expectRevert(dl);
        router.exactInputSingle(a);

        ISupaRouter.ExactInputParams memory b = _inMulti(_path1(tokenA, clammAB, tokenB), alice, 1 ether, 0);
        b.deadline = past;
        vm.prank(alice);
        vm.expectRevert(dl);
        router.exactInput(b);

        ISupaRouter.ExactOutputSingleParams memory c = _outSingle(clammAB, true, alice, 1 ether, type(uint128).max);
        c.deadline = past;
        vm.prank(alice);
        vm.expectRevert(dl);
        router.exactOutputSingle(c);

        ISupaRouter.ExactOutputParams memory d =
            _outMulti(_path1(tokenB, clammAB, tokenA), alice, 1 ether, type(uint128).max);
        d.deadline = past;
        vm.prank(alice);
        vm.expectRevert(dl);
        router.exactOutput(d);
    }

    function test_deadline_equalToNowPasses() public {
        ISupaRouter.ExactInputSingleParams memory a = _inSingle(clammAB, true, alice, 1 ether, 0);
        a.deadline = block.timestamp;
        vm.prank(alice);
        assertGt(router.exactInputSingle(a), 0);
    }

    // ---------------------------------------------------------------------
    //                        native ETH payment paths
    // ---------------------------------------------------------------------

    function test_nativeInput_insufficientETH_reverts() public {
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientETH.selector); // (consumed ~1 ether, 0.5 ether)
        router.exactInputSingle{value: 0.5 ether}(_inSingle(clammEthA, true, alice, 1 ether, 0));

        (uint256 quotedIn,,) = quoter.quoteExactOutputSingle(_qOut(binEthB, true, 1 ether));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.InsufficientETH.selector, quotedIn, 0));
        router.exactOutputSingle(_outSingle(binEthB, true, alice, 1 ether, type(uint128).max));
    }

    function test_nativeOutput_toRejectingRecipient_reverts() public {
        ETHRejecter rej = new ETHRejecter();
        vm.prank(alice);
        vm.expectRevert(); // SafeTransferLib.ETHTransferFailed
        router.exactInputSingle(_inSingle(clammEthA, false, address(rej), 1 ether, 0));
    }

    function test_nativeRefund_toRejectingPayer_reverts() public {
        ETHRejecter rej = new ETHRejecter();
        vm.deal(address(rej), 10 ether);
        vm.prank(address(rej));
        vm.expectRevert(); // excess-ETH refund to a payer that cannot receive ETH
        router.exactInputSingle{value: 2 ether}(_inSingle(clammEthA, true, alice, 1 ether, 0));
    }

    function test_nativeOutput_asClaims() public {
        ISupaRouter.ExactInputSingleParams memory p = _inSingle(binEthB, false, bob, 1 ether, 0);
        p.receiveAsClaims = true;
        vm.prank(alice);
        uint256 out = router.exactInputSingle(p);
        assertEq(vault.balanceOf(bob, ETH.toId()), out, "native claims minted");
        _assertClean();
    }

    // ---------------------------------------------------------------------
    //                        ERC-6909 claims paths
    // ---------------------------------------------------------------------

    function _mintClaims(address who, Currency c, uint128 amountOutWanted) internal {
        // Acquire claims of `c` by swapping into it with receiveAsClaims.
        PoolKey memory key = Currency.unwrap(c) == Currency.unwrap(tokenA) ? clammAB : binBC;
        bool zfo = Currency.unwrap(c) == Currency.unwrap(tokenA) ? false : true;
        ISupaRouter.ExactOutputSingleParams memory p = _outSingle(key, zfo, who, amountOutWanted, type(uint128).max);
        p.receiveAsClaims = true;
        vm.prank(who);
        router.exactOutputSingle(p);
        assertEq(vault.balanceOf(who, c.toId()), amountOutWanted);
    }

    function test_claims_payAndReceive_singleHop() public {
        _mintClaims(alice, tokenA, 10 ether);
        vm.prank(alice);
        vault.setOperator(address(router), true);

        ISupaRouter.ExactInputSingleParams memory p = _inSingle(stableAC, true, alice, 4 ether, 0);
        p.payWithClaims = true;
        p.receiveAsClaims = true;
        uint256 aErc20Before = rawA.balanceOf(alice);
        vm.prank(alice);
        uint256 out = router.exactInputSingle(p);
        assertEq(vault.balanceOf(alice, tokenA.toId()), 6 ether, "claims burned");
        assertEq(vault.balanceOf(alice, tokenC.toId()), out, "claims minted");
        assertEq(rawA.balanceOf(alice), aErc20Before, "no ERC20 pulled");
        _assertClean();
    }

    function test_claims_exactOutput_singleAndMulti() public {
        _mintClaims(alice, tokenC, 20 ether);
        vm.prank(alice);
        vault.approve(address(router), tokenC.toId(), type(uint256).max);

        ISupaRouter.ExactOutputSingleParams memory s = _outSingle(stableAC, false, alice, 2 ether, type(uint128).max);
        s.payWithClaims = true;
        vm.prank(alice);
        uint256 in1 = router.exactOutputSingle(s);
        assertEq(vault.balanceOf(alice, tokenC.toId()), 20 ether - in1);

        // want A, pay C claims: A <-CLAMM- B <-BIN- C ; output as claims
        ISupaRouter.ExactOutputParams memory m =
            _outMulti(_path2(tokenA, clammAB, tokenB, binBC, tokenC), bob, 1 ether, type(uint128).max);
        m.payWithClaims = true;
        m.receiveAsClaims = true;
        vm.prank(alice);
        uint256 in2 = router.exactOutput(m);
        assertEq(vault.balanceOf(alice, tokenC.toId()), 20 ether - in1 - in2);
        assertEq(vault.balanceOf(bob, tokenA.toId()), 1 ether);
        _assertClean();
    }

    function test_claims_exactInput_multi() public {
        _mintClaims(alice, tokenA, 10 ether);
        vm.prank(alice);
        vault.setOperator(address(router), true);
        ISupaRouter.ExactInputParams memory m =
            _inMulti(_path2(tokenA, clammAB, tokenB, binBC, tokenC), bob, 3 ether, 0);
        m.payWithClaims = true;
        m.receiveAsClaims = true;
        vm.prank(alice);
        uint256 out = router.exactInput(m);
        assertEq(vault.balanceOf(alice, tokenA.toId()), 7 ether);
        assertEq(vault.balanceOf(bob, tokenC.toId()), out);
        _assertClean();
    }

    function test_claims_withoutApproval_reverts() public {
        _mintClaims(alice, tokenA, 10 ether);
        ISupaRouter.ExactInputSingleParams memory p = _inSingle(clammAB, true, alice, 1 ether, 0);
        p.payWithClaims = true;
        vm.prank(alice);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        router.exactInputSingle(p);
    }

    function test_claims_cannotSpendSomeoneElsesClaims() public {
        // Alice approves the router; Bob tries to route a swap paid with claims. The router always uses msg.sender
        // as payer, so Bob can only spend his own (zero) claims.
        _mintClaims(alice, tokenA, 10 ether);
        vm.prank(alice);
        vault.setOperator(address(router), true);
        ISupaRouter.ExactInputSingleParams memory p = _inSingle(clammAB, true, bob, 1 ether, 0);
        p.payWithClaims = true;
        vm.prank(bob);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        router.exactInputSingle(p);
        assertEq(vault.balanceOf(alice, tokenA.toId()), 10 ether);
    }

    // ---------------------------------------------------------------------
    //                  callbacks, reentrancy, authorization
    // ---------------------------------------------------------------------

    function test_unlockCallback_onlyVault() public {
        bytes memory data = abi.encode(uint8(0), alice, _inSingle(clammAB, true, bob, 1 ether, 0));
        vm.prank(bob);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        router.unlockCallback(data);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        router.unlockCallback("");
    }

    function test_unlockCallback_spoofedPayerFromAttackerContractCannotReachRouter() public {
        // An attacker that unlocks the vault itself receives the callback on its own address, never the router's;
        // so it cannot make the router pull a victim's tokens. Calling the router callback directly is blocked.
        vm.prank(alice);
        rawA.approve(address(router), type(uint256).max);
        bytes memory data = abi.encode(uint8(0), alice, _inSingle(clammAB, true, bob, 1 ether, 0));
        vm.prank(bob);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        router.unlockCallback(data);
        assertEq(rawA.balanceOf(alice), 100_000 ether);
    }

    function _reentrantPool() internal returns (ReentrantToken re, PoolKey memory key) {
        re = new ReentrantToken();
        Currency cre = Currency.wrap(address(re));
        (Currency c0, Currency c1) = Currency.unwrap(cre) < Currency.unwrap(tokenB) ? (cre, tokenB) : (tokenB, cre);
        key = _key(c0, c1, 3000, 60, CurveType.CLAMM);
        manager.initialize(key, SQRT_1_1, "");
        re.mint(address(lp), LIQ);
        lp.addLiquidity(key, 100_000 ether);
        re.mint(alice, 1_000 ether);
        vm.prank(alice);
        re.approve(address(router), type(uint256).max);
    }

    /// @dev BUG (reported, not fixed): TransientStorageLib.acquireLock hard-codes 0x5462fc74 as the
    ///      "VaultErrors.VaultAlreadyLocked" selector, but keccak("VaultAlreadyLocked()")[:4] is 0xa6c62fd0. Re-entry
    ///      IS blocked; only the revert payload is wrong (undecodable by ABIs/frontends). See the PoC test below.
    bytes4 internal constant LOCK_REVERT_SELECTOR = 0x5462fc74;

    function test_PoC_vaultLockRevertSelectorMismatch() public {
        assertEq(VaultErrors.VaultAlreadyLocked.selector, bytes4(0xa6c62fd0), "declared error selector");
        // Re-enter vault.unlock while the router holds the lock: the payload is NOT VaultAlreadyLocked().
        (ReentrantToken re, PoolKey memory key) = _reentrantPool();
        bool zfo = Currency.unwrap(key.currency0) == address(re);
        re.arm(ReentrantToken.Mode.VAULT, router, abi.encodeWithSignature("unlock(bytes)", bytes("")));
        vm.prank(alice);
        router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
        assertFalse(re.lastOk(), "re-entry blocked");
        assertEq(re.lastRet().length, 4);
        assertEq(bytes4(re.lastRet()), bytes4(0x5462fc74), "PoC: lock reverts with 0x5462fc74");
        assertTrue(bytes4(re.lastRet()) != VaultErrors.VaultAlreadyLocked.selector, "PoC: selector mismatch");
    }

    function _assertReentryBlocked(ReentrantToken re, bytes4 expected) internal view {
        assertTrue(re.attempted(), "re-entry was attempted");
        assertFalse(re.lastOk(), "re-entry must fail");
        assertEq(bytes4(re.lastRet()), expected, "re-entry failure reason");
    }

    function test_reentrancy_tokenReentersRouterSwap_blocked() public {
        (ReentrantToken re, PoolKey memory key) = _reentrantPool();
        bool zfo = Currency.unwrap(key.currency0) == address(re);
        re.arm(
            ReentrantToken.Mode.ROUTER,
            router,
            abi.encodeCall(router.exactInputSingle, (_inSingle(clammAB, true, alice, 1 ether, 0)))
        );
        vm.prank(alice);
        uint256 out = router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
        assertGt(out, 0, "outer swap still settles");
        _assertReentryBlocked(re, LOCK_REVERT_SELECTOR);
        _assertClean();
    }

    function test_reentrancy_tokenReentersEveryRouterEntryPoint_blocked() public {
        bytes[3] memory inner = [
            abi.encodeCall(router.exactInput, (_inMulti(_path1(tokenA, clammAB, tokenB), alice, 1 ether, 0))),
            abi.encodeCall(router.exactOutputSingle, (_outSingle(clammAB, true, alice, 1 ether, 2 ether))),
            abi.encodeCall(router.exactOutput, (_outMulti(_path1(tokenB, clammAB, tokenA), alice, 1 ether, 2 ether)))
        ];
        for (uint256 i = 0; i < 3; i++) {
            (ReentrantToken re, PoolKey memory key) = _reentrantPool();
            bool zfo = Currency.unwrap(key.currency0) == address(re);
            re.arm(ReentrantToken.Mode.ROUTER, router, inner[i]);
            vm.prank(alice);
            router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
            _assertReentryBlocked(re, LOCK_REVERT_SELECTOR);
        }
        _assertClean();
    }

    function test_reentrancy_tokenCallsRouterCallback_blocked() public {
        // Mid-swap the vault IS unlocked, but the router callback still rejects any caller except the vault.
        (ReentrantToken re, PoolKey memory key) = _reentrantPool();
        bool zfo = Currency.unwrap(key.currency0) == address(re);
        bytes memory inner = abi.encodeCall(
            router.unlockCallback, (abi.encode(uint8(0), alice, _inSingle(clammAB, true, address(re), 1 ether, 0)))
        );
        re.arm(ReentrantToken.Mode.ROUTER, router, inner);
        uint256 aliceA = rawA.balanceOf(alice);
        vm.prank(alice);
        router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
        _assertReentryBlocked(re, VaultErrors.Unauthorized.selector);
        assertEq(rawA.balanceOf(alice), aliceA, "victim tokens untouched");
        _assertClean();
    }

    function test_reentrancy_tokenReentersVaultUnlock_blocked() public {
        (ReentrantToken re, PoolKey memory key) = _reentrantPool();
        bool zfo = Currency.unwrap(key.currency0) == address(re);
        re.arm(ReentrantToken.Mode.VAULT, router, abi.encodeWithSignature("unlock(bytes)", bytes("")));
        vm.prank(alice);
        router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
        _assertReentryBlocked(re, LOCK_REVERT_SELECTOR);
        _assertClean();
    }

    function test_reentrancy_tokenTakesFromVaultMidSwap_failsSettlement() public {
        // A hostile token that calls vault.take during the router's settlement only creates a debt for ITSELF,
        // so the unlock reverts with an unsettled delta and no funds leave the vault.
        (ReentrantToken re, PoolKey memory key) = _reentrantPool();
        bool zfo = Currency.unwrap(key.currency0) == address(re);
        bytes memory steal = abi.encodeWithSignature("take(address,address,uint256)", tokenB, address(re), 1 ether);
        re.arm(ReentrantToken.Mode.VAULT, router, steal);
        uint256 vaultB = rawB.balanceOf(address(vault));
        vm.prank(alice);
        vm.expectPartialRevert(VaultErrors.CurrencyNotSettled.selector);
        router.exactInputSingle(_inSingle(key, zfo, alice, 1 ether, 0));
        assertEq(rawB.balanceOf(address(vault)), vaultB);
        assertEq(rawB.balanceOf(address(re)), 0);
    }

    // ---------------------------------------------------------------------
    //                 PeripheryPayments: refundETH / sweepToken
    // ---------------------------------------------------------------------

    function test_receive_and_refundETH() public {
        vm.deal(address(this), 5 ether);
        (bool ok,) = address(router).call{value: 2 ether}("");
        assertTrue(ok, "router accepts ETH");
        uint256 before = bob.balance;
        vm.prank(bob);
        router.refundETH();
        assertEq(bob.balance - before, 2 ether, "refundETH sweeps router ETH to caller");
        // zero balance: no-op
        vm.prank(bob);
        router.refundETH();
        assertEq(bob.balance - before, 2 ether);
    }

    function test_refundETH_toRejectingCaller_reverts() public {
        ETHRejecter rej = new ETHRejecter();
        vm.deal(address(router), 1 ether);
        vm.prank(address(rej));
        vm.expectRevert();
        router.refundETH();
    }

    function test_sweepToken_erc20() public {
        rawC.mint(address(router), 7 ether);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(PeripheryErrors.SlippageExceeded.selector, 8 ether, 7 ether));
        router.sweepToken(tokenC, 8 ether, bob);
        vm.prank(bob);
        router.sweepToken(tokenC, 7 ether, bob);
        assertEq(rawC.balanceOf(bob), 100_000 ether + 7 ether);
        assertEq(rawC.balanceOf(address(router)), 0);
        // empty balance with zero minimum: no transfer, no revert
        router.sweepToken(tokenC, 0, bob);
    }

    function test_sweepToken_native() public {
        vm.deal(address(router), 3 ether);
        uint256 before = bob.balance;
        router.sweepToken(ETH, 3 ether, bob);
        assertEq(bob.balance - before, 3 ether);
    }

    function test_swap_sweepsStrandedETHToPayer() public {
        // ETH stranded on the router (e.g. a direct transfer) is returned to the next swapper by the post-swap
        // refund; documented v3-style behaviour (stranded periphery ETH is not protected).
        vm.deal(address(router), 1 ether);
        uint256 before = alice.balance;
        vm.prank(alice);
        router.exactInputSingle(_inSingle(clammAB, true, alice, 1 ether, 0));
        assertEq(alice.balance - before, 1 ether);
        _assertClean();
    }

    // ---------------------------------------------------------------------
    //                               multicall
    // ---------------------------------------------------------------------

    function test_multicall_mixedEntryPoints() public {
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(router.exactInputSingle, (_inSingle(binBC, true, alice, 1 ether, 0)));
        calls[1] = abi.encodeCall(router.exactOutputSingle, (_outSingle(stableAC, true, alice, 1 ether, 2 ether)));
        calls[2] = abi.encodeCall(
            router.exactInput, (_inMulti(_path2(tokenA, clammAB, tokenB, binBC, tokenC), alice, 1 ether, 0))
        );
        vm.prank(alice);
        bytes[] memory res = router.multicall(calls);
        assertEq(res.length, 3);
        assertGt(abi.decode(res[0], (uint256)), 0);
        assertGt(abi.decode(res[1], (uint256)), 0);
        assertGt(abi.decode(res[2], (uint256)), 0);
        _assertClean();
    }

    function test_multicall_bubblesInnerRevert() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.exactInputSingle, (_inSingle(binBC, true, alice, 1 ether, 0)));
        calls[1] = abi.encodeCall(router.exactInput, (_inMulti(new bytes(10), alice, 1 ether, 0)));
        vm.prank(alice);
        vm.expectRevert(PeripheryErrors.InvalidPath.selector);
        router.multicall(calls);
    }

    function test_multicall_empty() public {
        bytes[] memory res = router.multicall(new bytes[](0));
        assertEq(res.length, 0);
    }

    /// @notice Behaviour note (reported): every swap entry point refunds the router's whole ETH balance to the
    ///         caller when it finishes. Inside a multicall, the first native-input swap therefore refunds the ETH
    ///         meant for later calls, and a second native-input swap reverts with InsufficientETH. No ETH is lost
    ///         (msg.value cannot be double-spent because payment reads the live balance), but batching two
    ///         native-input swaps in one multicall does not work.
    function test_multicall_twoNativeInputSwaps_secondRevertsInsufficientETH() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.exactInputSingle, (_inSingle(clammEthA, true, alice, 1 ether, 0)));
        calls[1] = abi.encodeCall(router.exactInputSingle, (_inSingle(binEthB, true, alice, 1 ether, 0)));
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientETH.selector); // (consumed ~1 ether, 0)
        router.multicall{value: 2 ether}(calls);
    }

    function test_multicall_msgValueNotDoubleSpent() public {
        // Two native-input swaps cannot both spend one msg.value: the second sees an empty balance.
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(router.exactInputSingle, (_inSingle(clammEthA, true, alice, 1 ether, 0)));
        calls[1] = abi.encodeCall(router.exactInputSingle, (_inSingle(clammEthA, true, alice, 1 ether, 0)));
        vm.prank(alice);
        vm.expectPartialRevert(PeripheryErrors.InsufficientETH.selector); // (consumed ~1 ether, 0)
        router.multicall{value: 1 ether}(calls);
    }
}
