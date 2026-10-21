// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {ISupaRoles} from "../../contract/interfaces/ISupaRoles.sol";
import {SupaRoles} from "../../contract/governance/SupaRoles.sol";
import {IAggregatorV3} from "../../contract/interfaces/external/IAggregatorV3.sol";
import {PluginErrors} from "../../contract/errors/PluginErrors.sol";
import {IPluginEvents} from "../../contract/events/IPluginEvents.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {Slot0, Slot0Library} from "../../contract/types/Slot0.sol";

/// TEST-ONLY mock of a Chainlink-style aggregator (ADR-0009: mocks in tests only, never deployed).
contract MockAggregator {
    enum Mode {
        Normal,
        Revert,
        ShortReturn,
        BurnGas
    }

    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;
    Mode public mode;

    constructor(uint8 d) {
        decimals = d;
    }

    function set(int256 a, uint256 t) external {
        answer = a;
        updatedAt = t;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == Mode.Revert) revert("feed down");
        if (mode == Mode.ShortReturn) {
            assembly {
                mstore(0, 1)
                return(0, 32)
            }
        }
        if (mode == Mode.BurnGas) {
            uint256 x;
            while (gasleft() > 100) {
                x++;
            }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// TEST-ONLY mock of a Chainlink L2 sequencer-uptime feed (answer 0 = up, 1 = down; startedAt = status change).
contract MockSequencerFeed {
    int256 public answer;
    uint256 public startedAt;
    bool public broken;

    function set(int256 a, uint256 s) external {
        answer = a;
        startedAt = s;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (broken) revert("sequencer feed down");
        return (1, answer, startedAt, startedAt, 1);
    }
}

contract MockDecToken {
    uint8 public decimals;

    constructor(uint8 d) {
        decimals = d;
    }
}

/// @notice ADR-0009 oracle overlay: config validation, every fallback reason, arbitrage-direction-only surcharge,
///         deadband, decimals/invert scaling, gas-griefing guard, governance-only setters. The test contract acts as
///         the PoolManager (onlyPoolManager) and as roles owner (governance).
contract LVROracleTest is Test, IPluginEvents {
    using PoolIdLibrary for PoolKey;
    using Slot0Library for Slot0;

    uint256 internal constant Q96 = 2 ** 96;
    LVRShieldPlugin internal plugin;
    SupaRoles internal roles;
    MockAggregator internal feed;
    PoolKey internal key;
    Slot0 internal slot0;

    uint32 internal constant HEARTBEAT = 3600;
    uint16 internal constant ALPHA = 10_000;
    uint16 internal constant DEADBAND = 50;
    uint16 internal constant MAXDEV = 1_000;
    uint24 internal constant FALLBACK = 20_000;

    function setUp() public {
        vm.warp(1_700_000_000);
        plugin = new LVRShieldPlugin(IPoolManager(address(this)));
        roles = new SupaRoles(address(this), address(0xBEEF));
        plugin.setRoles(ISupaRoles(address(roles)));
        key = _mkKey(18, 18, CurveType.CLAMM, 60);
        _setPrice(1e18, 1e18); // pool price 1.0
        plugin.afterInitialize(address(this), key, 0, 0);
        feed = new MockAggregator(8);
        feed.set(1e8, block.timestamp);
    }

    // ------------------------------------------------------------------ manager mock
    function getSlot0(PoolId) external view returns (Slot0) {
        return slot0;
    }

    function getLiquidity(PoolId) external pure returns (uint128) {
        return 1e18;
    }

    // ------------------------------------------------------------------ helpers
    function _mkKey(uint8 d0, uint8 d1, CurveType ct, int24 spacing) internal returns (PoolKey memory k) {
        address a = address(new MockDecToken(d0));
        address b = address(new MockDecToken(d1));
        // currency0 < currency1 is not enforced by the plugin; keep decimals mapping explicit.
        k = PoolKey({
            currency0: Currency.wrap(a),
            currency1: Currency.wrap(b),
            fee: 3000,
            tickSpacing: spacing,
            plugin: address(plugin),
            curveType: ct
        });
    }

    function _isqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        z = x;
        uint256 y = (x >> 1) + 1;
        while (y < z) {
            z = y;
            y = (x / y + y) >> 1;
        }
    }

    /// pool raw price = num/den (token1 raw per token0 raw)
    function _setPrice(uint256 num, uint256 den) internal {
        uint256 sqrtP = _isqrt((num << 96) / den) << 48; // sqrt(num/den * 2^96) * 2^48 = sqrt(p) * 2^96
        slot0 = Slot0Library.pack(uint160(sqrtP), 0, 0, 3000, true);
    }

    function _configure() internal {
        plugin.setOracleConfig(key, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
    }

    function _fee(bool zeroForOne) internal returns (uint24 fee) {
        (, fee) = plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(zeroForOne, 1e18, 0), "");
    }

    function _expectFallback(uint8 reason) internal {
        vm.expectEmit(true, false, false, true, address(plugin));
        emit LVROracleFallback(key.toId(), reason);
        assertEq(_fee(true), FALLBACK, "fallback floor applied (> endogenous 3000)");
        (uint8 status,,,) = plugin.previewOracle(key.toId());
        assertEq(status, reason, "preview reports the same reason");
    }

    // ------------------------------------------------------------------ config validation
    function test_config_governanceOnly() public {
        vm.prank(address(0xBEEF)); // operator role has no power (APUS-SUPADEX-009)
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.PluginPermissionDenied.selector, address(plugin), 0));
        plugin.setOracleConfig(key, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.PluginPermissionDenied.selector, address(plugin), 0));
        plugin.clearOracleConfig(key);
        _configure(); // positive control
        assertEq(address(plugin.getOracleConfig(key.toId()).feed), address(feed));
    }

    function test_config_validationCodes() public {
        IAggregatorV3 f = IAggregatorV3(address(feed));
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(1)));
        plugin.setOracleConfig(key, IAggregatorV3(address(0)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(1)));
        plugin.setOracleConfig(key, IAggregatorV3(address(0x1234)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(2)));
        plugin.setOracleConfig(key, f, false, 59, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(2)));
        plugin.setOracleConfig(key, f, false, 2 days + 1, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(3)));
        plugin.setOracleConfig(key, f, false, HEARTBEAT, 10_001, DEADBAND, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(4)));
        plugin.setOracleConfig(key, f, false, HEARTBEAT, ALPHA, MAXDEV, MAXDEV, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(5)));
        plugin.setOracleConfig(key, f, false, HEARTBEAT, ALPHA, DEADBAND, 5_001, FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(6)));
        plugin.setOracleConfig(key, f, false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, 100_001);
        MockAggregator bad = new MockAggregator(19);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(7)));
        plugin.setOracleConfig(key, IAggregatorV3(address(bad)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
    }

    function test_config_tokenDecimalsAbove18Rejected() public {
        PoolKey memory k = _mkKey(19, 18, CurveType.CLAMM, 60);
        plugin.afterInitialize(address(this), k, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(8)));
        plugin.setOracleConfig(k, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
    }

    function test_config_uninitializedPoolRejected() public {
        PoolKey memory k = _mkKey(18, 18, CurveType.CLAMM, 10);
        vm.expectRevert(LVRShieldPlugin.OraclePoolNotInitialized.selector);
        plugin.setOracleConfig(k, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
    }

    function test_noFeed_previewIs255_andFeeIsEndogenous() public {
        (uint8 status,,,) = plugin.previewOracle(key.toId());
        assertEq(status, 255);
        assertEq(_fee(true), 3000);
    }

    // ------------------------------------------------------------------ valid feed
    function test_valid_atParity_noSurchargeEitherDirection() public {
        _configure();
        assertEq(_fee(true), 3000);
        assertEq(_fee(false), 3000);
        (uint8 status,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        assertEq(dev, 0);
    }

    function test_surcharge_onlyInArbitrageDirection() public {
        _configure();
        _setPrice(102, 100); // pool 2% above feed => selling token0 (zeroForOne) is the arbitrage
        (uint8 status,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        assertGe(dev, 199);
        assertLe(dev, 200);
        uint256 expected = 3000 + (dev - DEADBAND) * 100 * ALPHA / 10_000;
        vm.expectEmit(true, false, false, true, address(plugin));
        emit LVROracleSurcharge(key.toId(), dev, uint24(expected - 3000), true);
        assertEq(_fee(true), expected, "arb direction pays base + surcharge");
        assertEq(
            _fee(false), 3000, "non-arb direction (pushes away from the feed... but restores LP) pays endogenous only"
        );
        // lastFee stores only the endogenous fee (no compounding of the surcharge)
        (, uint24 lastFee,,,,,,,) = plugin.poolLVRStates(key.toId());
        assertEq(lastFee, 3000);
    }

    function test_surcharge_poolBelowFeed_oneForZeroIsArb() public {
        _configure();
        _setPrice(98, 100);
        assertEq(_fee(true), 3000);
        assertGt(_fee(false), 3000);
    }

    function test_deadband_noSurcharge() public {
        _configure();
        _setPrice(10_040, 10_000); // 40 bps < 50 bps deadband
        assertEq(_fee(true), 3000);
        assertEq(_fee(false), 3000);
    }

    function test_surcharge_clampedToMaxFee() public {
        _configure();
        _setPrice(109, 100); // ~9% < 10% max deviation; surcharge ~(900-50)*100 = ~85_000 + 3000 <= 100_000
        (,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertGe(dev, 899); // sqrt rounding of the mocked pool price
        assertEq(_fee(true), 3000 + (dev - DEADBAND) * 100);
        // widen max deviation to 20%: 15% deviation => 3000 + ~145_000 > maxFee 100_000 => clamped
        plugin.setOracleConfig(key, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, 2_000, FALLBACK);
        _setPrice(115, 100);
        assertEq(_fee(true), 100_000);
    }

    function test_decimalsAndInvertScaling() public {
        // token0 has 6 decimals, token1 18: raw price for human 1.0 is 1e12
        key = _mkKey(6, 18, CurveType.CLAMM, 60);
        _setPrice(1e12, 1);
        plugin.afterInitialize(address(this), key, 0, 0);
        _configure();
        (uint8 status,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        assertLe(dev, 1);
        // inverted feed quoting token0 per token1 = 1/2.0 while pool is at 2.0
        _setPrice(2e12, 1);
        feed.set(0.5e8, block.timestamp);
        plugin.setOracleConfig(key, IAggregatorV3(address(feed)), true, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        (status,,, dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        assertLe(dev, 1);
    }

    // ------------------------------------------------------------------ fallback reasons
    function test_fallback_revertingFeed() public {
        _configure();
        feed.setMode(MockAggregator.Mode.Revert);
        _expectFallback(1);
    }

    function test_fallback_wrongReturnSize() public {
        _configure();
        feed.setMode(MockAggregator.Mode.ShortReturn);
        _expectFallback(1);
    }

    function test_fallback_gasBurningFeedIsCapped() public {
        _configure();
        feed.setMode(MockAggregator.Mode.BurnGas);
        uint256 g = gasleft();
        _expectFallback(1);
        assertLt(g - gasleft(), 400_000, "feed call is gas-capped");
    }

    function test_fallback_nonPositiveAnswer() public {
        _configure();
        feed.set(0, block.timestamp);
        _expectFallback(2);
        feed.set(-1, block.timestamp);
        _expectFallback(2);
    }

    function test_fallback_stale() public {
        _configure();
        feed.set(1e8, block.timestamp - HEARTBEAT - 1);
        _expectFallback(3);
        feed.set(1e8, 0);
        _expectFallback(3);
        feed.set(1e8, block.timestamp - HEARTBEAT); // exactly at heartbeat: valid (positive control)
        assertEq(_fee(true), 3000);
    }

    function test_fallback_futureTimestamp() public {
        _configure();
        feed.set(1e8, block.timestamp + 1);
        _expectFallback(4);
    }

    function test_fallback_absurdAnswer() public {
        _configure();
        feed.set(int256(2 ** 100), block.timestamp);
        _expectFallback(5);
    }

    function test_fallback_deviationAboveMax() public {
        _configure();
        _setPrice(115, 100); // 15% > 10%
        // APUS-SUPADEX-023: beyond maxDeviation the arbitrage direction (pool above feed => zeroForOne) pays at least
        // base + the surcharge capped at maxDeviation. The non-arbitrage direction pays max(endogenous, fallback).
        uint256 capped = 3000 + ((uint256(MAXDEV) - DEADBAND) * 100 * ALPHA) / 10_000;
        vm.expectEmit(true, false, false, true, address(plugin));
        emit LVROracleFallback(key.toId(), 6);
        assertEq(_fee(true), capped > FALLBACK ? capped : FALLBACK, "arb direction: >= capped surcharge");
        vm.expectEmit(true, false, false, true, address(plugin));
        emit LVROracleFallback(key.toId(), 6);
        assertEq(_fee(false), FALLBACK, "non-arb direction: fallback");
    }

    /// APUS-SUPADEX-023 regression: push past maxDeviation, then return. The return leg must pay >= the fee of a direct
    /// arbitrage at any in-band deviation (surcharge monotone in deviation).
    function test_023_pushPastMaxDeviation_returnPaysAtLeastDirectArbFee() public {
        _configure();
        uint256 maxInBand;
        for (uint256 p = 101; p <= 110; p++) {
            _setPrice(p, 100); // pool above feed: arb direction is zeroForOne
            uint24 f = _fee(true);
            if (f > maxInBand) maxInBand = f;
        }
        _setPrice(150, 100); // beyond maxDeviation
        uint24 ret = _fee(true);
        assertGe(ret, maxInBand, "return leg beyond maxDeviation must not be cheaper than direct arbitrage");
    }

    function test_fallback_neverBelowEndogenous() public {
        plugin.setOracleConfig(key, IAggregatorV3(address(feed)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, 1);
        feed.setMode(MockAggregator.Mode.Revert);
        assertEq(_fee(true), 3000, "max(endogenous, fallback)");
    }

    function test_clearOracleConfig_restoresEndogenous() public {
        _configure();
        _setPrice(102, 100);
        assertGt(_fee(true), 3000);
        plugin.clearOracleConfig(key);
        assertEq(_fee(true), 3000);
        (uint8 status,,,) = plugin.previewOracle(key.toId());
        assertEq(status, 255);
    }

    // ------------------------------------------------------------------ adversarial: gas griefing
    /// A caller must not be able to force the (cheaper) fallback path by under-funding the feed call. For every
    /// gas budget the call either reverts or returns the correct surcharge fee; it never silently falls back.
    function test_gasGriefing_cannotForceFallback() public {
        _configure();
        _setPrice(102, 100);
        uint24 honest = _fee(true);
        assertGt(honest, 3000);
        uint256 successes;
        for (uint256 g = 40_000; g <= 400_000; g += 5_000) {
            vm.recordLogs();
            try plugin.beforeSwap{gas: g}(address(this), key, IPoolManager.SwapParams(true, 1e18, 0), "") returns (
                bytes4, uint24 fee
            ) {
                assertEq(fee, honest, "under-funded call returned a different fee");
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 i; i < logs.length; i++) {
                    assertTrue(logs[i].topics[0] != LVROracleFallback.selector, "fallback forced by gas");
                }
                successes++;
            } catch {}
        }
        assertGt(successes, 0, "positive control: adequately funded calls succeed");
    }

    function test_gasGuard_specificError() public {
        _configure();
        // Enough gas for the endogenous step but not for the feed reserve => explicit PluginGasExceeded.
        bool sawGuard;
        for (uint256 g = 60_000; g <= 160_000; g += 2_000) {
            try plugin.beforeSwap{gas: g}(address(this), key, IPoolManager.SwapParams(true, 1e18, 0), "") {}
            catch (bytes memory err) {
                if (err.length >= 4 && bytes4(err) == PluginErrors.PluginGasExceeded.selector) sawGuard = true;
            }
        }
        assertTrue(sawGuard, "guard reverts with PluginGasExceeded for some under-funded budget");
    }

    // ------------------------------------------------------------------ fuzz
    function testFuzz_feeBounds(uint16 devBps, bool above, bool zeroForOne) public {
        _configure();
        devBps = uint16(bound(devBps, 0, 2_000));
        uint256 num = above ? 10_000 + devBps : 10_000 - devBps;
        _setPrice(num, 10_000);
        (, uint24 fee) = plugin.beforeSwap(address(this), key, IPoolManager.SwapParams(zeroForOne, 1e18, 0), "");
        (,,,,,, uint24 minFee, uint24 maxFee,) = plugin.poolLVRStates(key.toId());
        assertGe(fee, 3000, "never below endogenous");
        assertGe(fee, minFee);
        assertLe(fee, maxFee);
        bool arb = zeroForOne == above;
        if (!arb && devBps <= MAXDEV - 1) assertEq(fee, 3000, "non-arb direction never surcharged");
    }

    // ------------------------------------------------------------------ BIN normalisation
    function test_binTickNormalisedByBinStep() public {
        PoolKey memory k = _mkKey(18, 18, CurveType.BIN_AMM, 10);
        plugin.afterInitialize(address(this), k, 0, 7);
        (,,, int24 lastTick,,,,,) = plugin.poolLVRStates(k.toId());
        assertEq(lastTick, 70);
    }

    // ------------------------------------------------------------------ remediation-3: L2 sequencer (Edith 9-A)
    function _seqSetup(int256 answer, uint256 startedAt) internal returns (MockSequencerFeed seq) {
        seq = new MockSequencerFeed();
        seq.set(answer, startedAt);
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 3600);
        _configure();
        _setPrice(102, 100); // 2% above feed: a valid feed would surcharge zeroForOne
    }

    function test_sequencer_down_fallsBack() public {
        _seqSetup(1, block.timestamp - 10 days);
        _expectFallback(7);
    }

    function test_sequencer_withinGrace_fallsBack() public {
        _seqSetup(0, block.timestamp - 3600); // restarted exactly 1 h ago: still within (<=) grace
        _expectFallback(7);
    }

    function test_sequencer_upPastGrace_usesFeed() public {
        _seqSetup(0, block.timestamp - 3601);
        (uint8 status,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0, "feed trusted once grace elapsed");
        assertApproxEqAbs(dev, 200, 1);
        assertGt(_fee(true), 3000, "arbitrage surcharge applies");
    }

    function test_sequencer_malformedResponsesFallBack() public {
        MockSequencerFeed seq = _seqSetup(0, 0); // startedAt == 0 (uninitialised round)
        _expectFallback(7);
        seq.set(0, block.timestamp + 1); // future
        _expectFallback(7);
        seq.set(0, block.timestamp - 1 days);
        seq.setBroken(true); // reverting feed
        _expectFallback(7);
    }

    function test_sequencer_restartThenRecover() public {
        MockSequencerFeed seq = _seqSetup(1, block.timestamp - 1 days);
        _expectFallback(7);
        seq.set(0, block.timestamp); // back up now
        vm.warp(block.timestamp + 1800);
        _expectFallback(7);
        vm.warp(block.timestamp + 1801);
        feed.set(1e8, block.timestamp); // keep the price feed fresh
        (uint8 status,,,) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
    }

    function test_sequencer_configValidation() public {
        MockSequencerFeed seq = new MockSequencerFeed();
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(9)));
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(0x1234)), 3600); // no code
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(10)));
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 3599);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(10)));
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 1 days + 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.PluginPermissionDenied.selector, address(plugin), 0));
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 3600);
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 3600);
        assertEq(address(plugin.sequencerUptimeFeed()), address(seq));
        assertEq(plugin.sequencerGracePeriod(), 3600);
        // clearing allowed on a non-L2 chain id (31337)
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(0)), 0);
        assertEq(address(plugin.sequencerUptimeFeed()), address(0));
    }

    /// On a known L2 (Base 8453) a price feed cannot be configured until the uptime feed is set, and the uptime
    /// feed cannot be cleared there.
    function test_sequencer_requiredOnKnownL2() public {
        vm.chainId(8453);
        assertTrue(plugin.isKnownL2(8453) && plugin.isKnownL2(84532) && !plugin.isKnownL2(1));
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(9)));
        _configure();
        MockSequencerFeed seq = new MockSequencerFeed();
        seq.set(0, block.timestamp - 2 days);
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(seq)), 3600);
        _configure();
        (uint8 status,,,) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        vm.expectRevert(abi.encodeWithSelector(PluginErrors.InvalidOracleConfig.selector, uint8(9)));
        plugin.setSequencerUptimeFeed(IAggregatorV3(address(0)), 0);
    }

    /// The gas guard covers BOTH calls when an uptime feed is set: under-funding never forces fallback.
    function test_sequencer_gasGriefing_cannotForceFallback() public {
        _seqSetup(0, block.timestamp - 2 days);
        uint24 honest = _fee(true);
        assertGt(honest, 3000);
        uint256 successes;
        for (uint256 g = 60_000; g <= 500_000; g += 5_000) {
            vm.recordLogs();
            try plugin.beforeSwap{gas: g}(address(this), key, IPoolManager.SwapParams(true, 1e18, 0), "") returns (
                bytes4, uint24 fee
            ) {
                assertEq(fee, honest, "under-funded call returned a different fee");
                Vm.Log[] memory logs = vm.getRecordedLogs();
                for (uint256 i; i < logs.length; i++) {
                    assertTrue(logs[i].topics[0] != LVROracleFallback.selector, "fallback forced by gas");
                }
                successes++;
            } catch {}
        }
        assertGt(successes, 0);
    }

    // ------------------------------------------------------------------ remediation-3: feed lag + decimals (9-C)

    /// Documented limitation (ADR-0009, Edith 9-C): a feed that lags WITHIN its heartbeat is still "valid".
    /// Scenario: the true market moves 1.00 -> 1.03; neither the pool nor the feed has updated yet. The arbitrageur
    /// buying token0 (oneForZero) at the stale 1.00 pool price captures ~3% of LVR, but deviation(pool, feed) = 0,
    /// so the overlay charges only the endogenous fee: the LP is UNDER-charged until the feed publishes (Chainlink
    /// publishes on its deviation threshold or heartbeat, whichever first). This pins the behaviour; it is not a
    /// guarantee. Mitigation: deadband >= feed deviation threshold and heartbeat <= published + 10% (runbook).
    function test_feedLag_withinHeartbeat_underCharges() public {
        _configure();
        feed.set(1e8, block.timestamp); // feed still reports 1.00
        vm.warp(block.timestamp + HEARTBEAT - 1); // fresh by the heartbeat rule
        _setPrice(1, 1); // pool also still at 1.00 (true market is 1.03)
        (uint8 status,,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0, "lagging-but-fresh feed is accepted");
        assertLe(dev, 1);
        assertEq(_fee(false), 3000, "arbitrage against the true price pays only the base/endogenous fee");
        // When the feed publishes 1.03 the same (still unarbitraged) pool is surcharged in the arb direction.
        feed.set(1.03e8, block.timestamp);
        (,,, dev) = plugin.previewOracle(key.toId());
        assertApproxEqAbs(dev, 291, 1); // |1.00 - 1.03| / 1.03
        assertGt(_fee(false), 3000, "surcharge once the feed catches up");
        assertEq(_fee(true), 3000, "non-arbitrage direction unaffected");
        // One second past the heartbeat without an update the feed is rejected (reason 3 -> fallback floor).
        vm.warp(block.timestamp + HEARTBEAT + 1);
        _expectFallback(3);
    }

    /// Non-8-decimal feeds (6, 18, 0) scale to the same pool-price comparison.
    function testFuzz_feedDecimals_scaleConsistently(uint8 feedDec, uint16 bpsAbove) public {
        feedDec = uint8(bound(feedDec, 0, 18));
        bpsAbove = uint16(bound(bpsAbove, 0, 900));
        MockAggregator f = new MockAggregator(feedDec);
        f.set(int256(10 ** feedDec), block.timestamp); // price 1.0 in feed units
        plugin.setOracleConfig(key, IAggregatorV3(address(f)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
        _setPrice(10_000 + uint256(bpsAbove), 10_000);
        (uint8 status, uint256 oq,, uint256 dev) = plugin.previewOracle(key.toId());
        assertEq(status, 0);
        assertEq(oq, Q96, "1.0 in any feed decimals == 1.0 in Q96");
        assertApproxEqAbs(dev, bpsAbove, 1);
    }

    function test_feedDecimals_6and18_matchEightDecimal() public {
        uint8[3] memory decs = [uint8(6), uint8(8), uint8(18)];
        uint256 ref;
        for (uint256 i; i < 3; i++) {
            MockAggregator f = new MockAggregator(decs[i]);
            f.set(int256(2 * 10 ** decs[i]), block.timestamp); // 2.0
            plugin.setOracleConfig(key, IAggregatorV3(address(f)), false, HEARTBEAT, ALPHA, DEADBAND, MAXDEV, FALLBACK);
            (, uint256 oq,,) = plugin.previewOracle(key.toId());
            if (i == 0) ref = oq;
            assertEq(oq, ref, "same Q96 price for 6/8/18-decimal feeds");
            assertEq(oq, 2 * Q96);
        }
    }
}
