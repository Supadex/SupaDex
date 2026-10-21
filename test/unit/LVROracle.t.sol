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
        assertEq(_fee(false), 3000, "non-arb direction (pushes away from the feed... but restores LP) pays endogenous only");
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
        _expectFallback(6);
        assertEq(_fee(false), FALLBACK, "fallback applies to both directions");
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
}
