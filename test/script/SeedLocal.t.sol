// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeploySupaDex} from "../../script/DeploySupaDex.s.sol";
import {SeedLocal} from "../../script/SeedLocal.s.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {ISupaQuoter} from "../../contract/interfaces/ISupaQuoter.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey} from "../../contract/types/PoolKey.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {MockChainlinkAggregator, MockSequencerUptimeFeed} from "../../contract/test/MockChainlinkFeeds.sol";

/// @notice Gideon item 8: the official local seed creates all five pool flavours with liquidity, wires the LVR
///         oracle overlay through the timelock (no bypass), and its mock-feed helpers drive every UI state.
contract SeedLocalTest is Test {
    DeploySupaDex deployer;
    SeedLocal seeder;
    DeploySupaDex.DeploymentResult res;
    SeedLocal.Seeded s;
    address constant PROPOSER = address(0xA017);
    address constant EXECUTOR = address(0xA018);

    function setUp() external {
        vm.warp(1_800_000_000);
        deployer = new DeploySupaDex();
        seeder = new SeedLocal();
        res = deployer.deploy(
            address(deployer),
            DeploySupaDex.RoleConfig({
                governance: address(0xA011),
                proposer: PROPOSER,
                executor: EXECUTOR,
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
            SeedLocal.Addrs({
                poolManager: res.poolManager,
                positionManager: res.positionManager,
                lvrPlugin: res.lvrShieldPlugin,
                antiJITPlugin: res.antiJITPlugin,
                timelock: res.timelock
            })
        );
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        vm.startPrank(PROPOSER);
        tl.schedule(res.lvrShieldPlugin, 0, s.seqCall, 0, seeder.SALT_SEQ(), 1 hours);
        tl.schedule(res.lvrShieldPlugin, 0, s.oracleCall, 0, seeder.SALT_ORACLE(), 1 hours);
        vm.stopPrank();
    }

    function _execute() internal {
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.startPrank(EXECUTOR);
        tl.execute(res.lvrShieldPlugin, 0, s.seqCall, 0, seeder.SALT_SEQ());
        tl.execute(res.lvrShieldPlugin, 0, s.oracleCall, 0, seeder.SALT_ORACLE());
        vm.stopPrank();
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "fresh", 0);
    }

    function _quote(PoolKey memory k) internal returns (uint256 out, uint24 fee) {
        // 0.001 token0 in human units (token0 may be 6-decimal mUSDC on the stable pool)
        uint128 amt = Currency.unwrap(k.currency0) == s.usdc ? 1e3 : 1e15;
        (out,,, fee) = ISupaQuoter(res.quoter)
            .quoteExactInputSingleWithFee(
                ISupaQuoter.QuoteExactInputSingleParams({
                    poolKey: k, zeroForOne: true, amountIn: amt, sqrtPriceLimitX96: 0, hookData: ""
                })
            );
    }

    function test_allFivePoolsHaveLiquidityAndQuote() public {
        PoolKey[5] memory ks = [s.clamm, s.clammLvr, s.clammAntiJit, s.stable, s.bin];
        IPoolManager pm = IPoolManager(res.poolManager);
        for (uint256 i; i < 5; i++) {
            assertTrue(pm.getSlot0(ks[i].toId()).isInitialized(), "initialized");
            (uint256 out,) = _quote(ks[i]);
            assertGt(out, 0, "quotable");
        }
        assertEq(uint8(s.stable.curveType), 2);
        assertEq(s.stable.tickSpacing, 1);
    }

    function test_governanceOpsNeedTheDelay() public {
        SupaTimelock tl = SupaTimelock(payable(res.timelock));
        bytes32 salt = seeder.SALT_ORACLE();
        vm.prank(EXECUTOR);
        vm.expectRevert();
        tl.execute(res.lvrShieldPlugin, 0, s.oracleCall, 0, salt);
        (uint8 st,,,) = LVRShieldPlugin(res.lvrShieldPlugin).previewOracle(s.clammLvr.toId());
        assertEq(st, 255, "no oracle config before the timelock executes");
    }

    function test_feedStates_driveOracleStatus() public {
        _execute();
        LVRShieldPlugin lvr = LVRShieldPlugin(res.lvrShieldPlugin);
        (uint8 st,,, uint256 dev) = lvr.previewOracle(s.clammLvr.toId());
        assertEq(st, 0, "fresh = healthy");
        assertLe(dev, 1, "feed synced to pool price");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "deviate", 200);
        (st,,, dev) = lvr.previewOracle(s.clammLvr.toId());
        assertEq(st, 0);
        assertApproxEqAbs(dev, 196, 3, "~2% deviation (relative to oracle)");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "stale", 0);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertTrue(st != 0, "stale -> fallback");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "invalid", 0);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertTrue(st != 0, "invalid -> fallback");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "reverting", 0);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertTrue(st != 0, "reverting -> fallback");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "fresh", 0);
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "seq-down", 0);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertEq(st, 7, "sequencer down -> reason 7");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "seq-recent", 600);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertEq(st, 7, "within grace -> reason 7");

        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "seq-up", 0);
        (st,,,) = lvr.previewOracle(s.clammLvr.toId());
        assertEq(st, 0, "recovered");
    }

    function test_lvrQuoteReportsFallbackFeeWhenStale() public {
        _execute();
        seeder.setFeedState(s.priceFeed, s.sequencerFeed, res.poolManager, s.clammLvr.toId(), "stale", 0);
        (, uint24 fee) = _quote(s.clammLvr);
        assertGe(fee, seeder.FALLBACK_FEE_PIPS(), "fallback floor applied and reported by the quoter");
    }

    function test_mocksRefuseNonLocalChains() public {
        vm.chainId(84532);
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkAggregator.LocalChainOnly.selector, 84532));
        new MockChainlinkAggregator(8, "x", 1);
        vm.expectRevert(abi.encodeWithSelector(MockSequencerUptimeFeed.LocalChainOnly.selector, 84532));
        new MockSequencerUptimeFeed();
    }
}
