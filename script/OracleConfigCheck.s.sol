// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {LVRShieldPlugin} from "../contract/plugins/native/LVRShieldPlugin.sol";
import {PoolKey, CurveType} from "../contract/types/PoolKey.sol";
import {PoolId} from "../contract/types/PoolId.sol";
import {Currency} from "../contract/types/Currency.sol";
import {DeployEnvironment} from "./DeployEnvironment.sol";

interface IFeedMeta {
    function description() external view returns (string memory);
    function decimals() external view returns (uint8);
}

/**
 * @title OracleConfigCheck (read-only; ADR-0009 runbook, Edith remediation-3 condition 9)
 * @notice Verifies an LVR pool's oracle overlay against a reviewed registry entry BEFORE the timelock call is
 *         scheduled (dry run against a fork of the target chain), and again AFTER it executes. Acceptable feeds are
 *         ONLY official same-chain Chainlink direct-pair proxies (no composite / derived / cross-chain feeds).
 *         Registry entries live in config/oracle-feeds.json and must be copied from data.chain.link / docs.chain.link
 *         by one reviewer and checked by a second (see docs/runbooks/LVR-ORACLE-FEEDS.md).
 *         It sends no transactions.
 */
contract OracleConfigCheck is Script {
    struct FeedEntry {
        uint256 chainId;
        address feed; // official Chainlink proxy (EACAggregatorProxy) address
        string description; // exact on-chain description(), e.g. "ETH / USD"
        uint8 decimals;
        uint32 publishedHeartbeat; // seconds, from the Chainlink feed page
        uint16 publishedDeviationBps; // deviation threshold, bps (0.5% = 50)
        address base; // pool token the feed prices (e.g. WETH)
        address quote; // pool token in which it is quoted (e.g. USDC)
        bool directPair; // must be true: feed is base/quote itself, not composed
        address sequencerFeed; // official L2 sequencer-uptime feed on known L2s, else address(0)
    }

    struct Report {
        uint256 checks;
        uint256 failures;
    }

    uint256 internal constant HEARTBEAT_SLACK_PCT = 110; // configured heartbeat <= published + 10 %

    function run() external view {
        string memory j = vm.readFile(vm.envOr("ORACLE_REGISTRY", string("config/oracle-feeds.json")));
        string memory k = string.concat(".", vm.envString("ORACLE_ENTRY"));
        FeedEntry memory e = FeedEntry({
            chainId: vm.parseJsonUint(j, string.concat(k, ".chainId")),
            feed: vm.parseJsonAddress(j, string.concat(k, ".feed")),
            description: vm.parseJsonString(j, string.concat(k, ".description")),
            decimals: uint8(vm.parseJsonUint(j, string.concat(k, ".decimals"))),
            publishedHeartbeat: uint32(vm.parseJsonUint(j, string.concat(k, ".publishedHeartbeat"))),
            publishedDeviationBps: uint16(vm.parseJsonUint(j, string.concat(k, ".publishedDeviationBps"))),
            base: vm.parseJsonAddress(j, string.concat(k, ".base")),
            quote: vm.parseJsonAddress(j, string.concat(k, ".quote")),
            directPair: vm.parseJsonBool(j, string.concat(k, ".directPair")),
            sequencerFeed: vm.parseJsonAddress(j, string.concat(k, ".sequencerFeed"))
        });
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(vm.envAddress("POOL_CURRENCY0")),
            currency1: Currency.wrap(vm.envAddress("POOL_CURRENCY1")),
            fee: uint24(vm.envUint("POOL_FEE")),
            tickSpacing: int24(int256(vm.envUint("POOL_TICK_SPACING"))),
            plugin: vm.envAddress("LVR_PLUGIN"),
            curveType: CurveType.CLAMM
        });
        Report memory r = check(LVRShieldPlugin(key.plugin), key, e);
        console2.log("Oracle config checks:", r.checks, "failures:", r.failures);
        if (r.failures != 0) revert(DeployEnvironment.DEPLOYMENT_BLOCKED);
    }

    function check(LVRShieldPlugin lvr, PoolKey memory key, FeedEntry memory e) public view returns (Report memory r) {
        LVRShieldPlugin.OracleConfig memory cfg = lvr.getOracleConfig(key.toId());
        _expect(r, e.chainId == block.chainid, "registry entry is for this chain (same-chain feed)");
        _expect(r, e.directPair, "registry entry is a direct pair (no composite feed)");
        _expect(r, address(cfg.feed) == e.feed && e.feed != address(0), "configured feed is the registry proxy");
        _expect(r, e.feed.code.length > 0, "feed has code on this chain");
        if (e.feed.code.length > 0) {
            _expect(r, _eq(_description(e.feed), e.description), "on-chain description matches registry");
            _expect(r, IFeedMeta(e.feed).decimals() == e.decimals, "on-chain decimals match registry");
        }
        _expect(r, cfg.feedDecimals == e.decimals, "plugin cached feed decimals");
        // Token mapping: invert=false means the feed prices currency0 in currency1.
        address b = Currency.unwrap(cfg.invert ? key.currency1 : key.currency0);
        address q = Currency.unwrap(cfg.invert ? key.currency0 : key.currency1);
        _expect(r, b == e.base && q == e.quote, "pool tokens + invert flag match the feed's base/quote");
        _expect(
            r,
            uint256(cfg.heartbeat) * 100 <= uint256(e.publishedHeartbeat) * HEARTBEAT_SLACK_PCT,
            "heartbeat <= published heartbeat + 10%"
        );
        _expect(
            r, cfg.heartbeat >= e.publishedHeartbeat, "heartbeat not tighter than published (avoids constant fallback)"
        );
        _expect(r, cfg.deadbandBps >= e.publishedDeviationBps, "deadband >= published deviation threshold");
        _expect(r, cfg.maxDeviationBps > cfg.deadbandBps, "maxDeviation > deadband");
        if (lvr.isKnownL2(block.chainid)) {
            _expect(
                r,
                address(lvr.sequencerUptimeFeed()) == e.sequencerFeed && e.sequencerFeed != address(0),
                "L2: sequencer-uptime feed is the registry feed"
            );
            _expect(r, lvr.sequencerGracePeriod() >= 3600, "L2: sequencer grace >= 1 h");
        }
        (uint8 status,,, uint256 dev) = lvr.previewOracle(key.toId());
        _expect(r, status == 0, "previewOracle status 0 (fresh, valid, within maxDeviation)");
        if (status == 0) _expect(r, dev <= cfg.maxDeviationBps, "current pool/feed deviation within maxDeviation");
    }

    function _description(address feed) internal view returns (string memory) {
        try IFeedMeta(feed).description() returns (string memory d) {
            return d;
        } catch {
            return "";
        }
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _expect(Report memory r, bool ok, string memory what) internal pure {
        r.checks++;
        if (!ok) {
            r.failures++;
            console2.log("FAIL:", what);
        }
    }
}
