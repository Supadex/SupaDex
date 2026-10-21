// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySupaDex} from "../../script/DeploySupaDex.s.sol";
import {SeedLocal} from "../../script/SeedLocal.s.sol";
import {OracleConfigCheck} from "../../script/OracleConfigCheck.s.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {Currency} from "../../contract/types/Currency.sol";

/// @notice Condition 9: the feed-config runbook check accepts only the reviewed registry feed with sane parameters.
contract OracleConfigCheckTest is Test {
    DeploySupaDex.DeploymentResult res;
    SeedLocal seeder;
    SeedLocal.Seeded s;
    OracleConfigCheck checker;

    function setUp() external {
        vm.warp(1_800_000_000);
        DeploySupaDex d = new DeploySupaDex();
        seeder = new SeedLocal();
        checker = new OracleConfigCheck();
        res = d.deploy(
            address(d),
            DeploySupaDex.RoleConfig({
                governance: address(0xA011),
                proposer: address(0xA017),
                executor: address(0xA018),
                canceller: address(0xA019),
                guardian: address(0xA012),
                operator: address(0xA013),
                dao: address(0xA014),
                staking: address(0xA015),
                insurance: address(0xA016),
                timelockDelay: 1 hours
            })
        );
        s = seeder.seed(
            SeedLocal.Addrs(res.poolManager, res.positionManager, res.lvrShieldPlugin, res.antiJITPlugin, res.timelock)
        );
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        bytes32 a = seeder.SALT_SEQ();
        bytes32 b = seeder.SALT_ORACLE();
        vm.startPrank(address(0xA017));
        tl.schedule(res.lvrShieldPlugin, 0, s.seqCall, 0, a, 1 hours);
        tl.schedule(res.lvrShieldPlugin, 0, s.oracleCall, 0, b, 1 hours);
        vm.stopPrank();
        vm.warp(block.timestamp + 1 hours + 1);
        vm.startPrank(address(0xA018));
        tl.execute(res.lvrShieldPlugin, 0, s.seqCall, 0, a);
        tl.execute(res.lvrShieldPlugin, 0, s.oracleCall, 0, b);
        vm.stopPrank();
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "fresh", 0);
    }

    function _entry() internal view returns (OracleConfigCheck.FeedEntry memory) {
        return OracleConfigCheck.FeedEntry({
            chainId: block.chainid,
            feed: s.priceFeed,
            description: "mock token1 / token0",
            decimals: 8,
            publishedHeartbeat: 3600,
            publishedDeviationBps: 30,
            base: Currency.unwrap(s.clammLvr.currency0),
            quote: Currency.unwrap(s.clammLvr.currency1),
            directPair: true,
            sequencerFeed: s.sequencerFeed
        });
    }

    function _fails(OracleConfigCheck.FeedEntry memory e) internal view returns (uint256) {
        return checker.check(LVRShieldPlugin(res.lvrShieldPlugin), s.clammLvr, e).failures;
    }

    function test_reviewedEntryPasses() public view {
        OracleConfigCheck.Report memory r = checker.check(LVRShieldPlugin(res.lvrShieldPlugin), s.clammLvr, _entry());
        assertEq(r.failures, 0);
        assertGe(r.checks, 13);
    }

    function test_rejectsNonRegistryFeed() public view {
        OracleConfigCheck.FeedEntry memory e = _entry();
        e.feed = address(0xFEED);
        assertGt(_fails(e), 0);
    }

    function test_rejectsCompositeOrOtherChain() public view {
        OracleConfigCheck.FeedEntry memory e = _entry();
        e.directPair = false;
        assertGt(_fails(e), 0);
        e = _entry();
        e.chainId = 1;
        assertGt(_fails(e), 0);
    }

    function test_rejectsDescriptionOrDecimalsMismatch() public view {
        OracleConfigCheck.FeedEntry memory e = _entry();
        e.description = "ETH / USD";
        assertGt(_fails(e), 0);
        e = _entry();
        e.decimals = 18;
        assertGt(_fails(e), 0);
    }

    function test_rejectsHeartbeatAndDeadband() public view {
        OracleConfigCheck.FeedEntry memory e = _entry();
        e.publishedHeartbeat = 3000; // configured 3600 > 3000 * 1.1
        assertGt(_fails(e), 0);
        e = _entry();
        e.publishedHeartbeat = 86_400; // configured 3600 tighter than published: constant fallback
        assertGt(_fails(e), 0);
        e = _entry();
        e.publishedDeviationBps = 50; // deadband 30 < published deviation 50
        assertGt(_fails(e), 0);
    }

    function test_rejectsTokenMismatch() public view {
        OracleConfigCheck.FeedEntry memory e = _entry();
        (e.base, e.quote) = (e.quote, e.base); // would need invert = true
        assertGt(_fails(e), 0);
    }

    function test_rejectsStaleOrDownFeedNow() public {
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "stale", 0);
        assertGt(_fails(_entry()), 0);
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "fresh", 0);
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "seq-down", 0);
        assertGt(_fails(_entry()), 0, "sequencer down -> previewOracle status 7");
    }

    function test_l2RequiresRegistrySequencerFeed() public {
        vm.chainId(8453);
        OracleConfigCheck.FeedEntry memory e = _entry();
        e.chainId = 8453;
        assertEq(_fails(e), 0, "matching sequencer feed passes on an L2");
        e.sequencerFeed = address(0x5E9);
        assertGt(_fails(e), 0, "a different sequencer feed is rejected");
    }

    /// Edith R3.4-2: 1101 / 5000 / 81457 (and unknown ids) are sequencer-required; the check demands the registry
    /// uptime feed there and rejects an entry without one. On the local exempt chain it is not required.
    function test_failClosed_rollupsRequireRegistrySequencerFeed() public {
        uint256[4] memory ids = [uint256(1101), 5000, 81457, 999_999_999];
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            OracleConfigCheck.FeedEntry memory e = _entry();
            e.chainId = ids[i];
            assertEq(_fails(e), 0, "matching sequencer feed passes");
            e.sequencerFeed = address(0);
            assertGt(_fails(e), 0, "missing registry sequencer feed is rejected");
            e.sequencerFeed = address(0x5E9);
            assertGt(_fails(e), 0, "a different sequencer feed is rejected");
        }
    }
}
