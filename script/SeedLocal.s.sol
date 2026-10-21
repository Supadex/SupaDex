// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {TestMintableERC20} from "../contract/test/TestMintableERC20.sol";
import {MockChainlinkAggregator, MockSequencerUptimeFeed} from "../contract/test/MockChainlinkFeeds.sol";
import {IPoolManager} from "../contract/interfaces/IPoolManager.sol";
import {ISupaPositionManager} from "../contract/interfaces/ISupaPositionManager.sol";
import {SupaTimelock} from "../contract/governance/SupaTimelock.sol";
import {LVRShieldPlugin} from "../contract/plugins/native/LVRShieldPlugin.sol";
import {IAggregatorV3} from "../contract/interfaces/external/IAggregatorV3.sol";
import {PoolKey, CurveType} from "../contract/types/PoolKey.sol";
import {PoolId} from "../contract/types/PoolId.sol";
import {Currency} from "../contract/types/Currency.sol";
import {Slot0, Slot0Library} from "../contract/types/Slot0.sol";
import {TickMathLib} from "../contract/libraries/TickMathLib.sol";
import {FullMathLib} from "../contract/libraries/FullMathLib.sol";

/**
 * @title SeedLocal (LOCAL ANVIL ONLY)
 * @notice Official local seed for frontend work (Gideon item 8). It runs after DeploySupaDex on chain 31337:
 *   - deploys mWETH (18), mDAI (18), mUSDC (6) test tokens and a TEST-ONLY mock Chainlink feed + sequencer feed;
 *   - creates 5 pools with liquidity through SupaPositionManager:
 *       CLAMM mWETH/mDAI (no plugin), CLAMM + LVRShield, CLAMM + AntiJIT, STABLE mUSDC/mDAI (A = 100),
 *       BIN mWETH/mDAI (bin step 25, 21 bins around the active bin);
 *   - schedules the two governance calls that wire the LVR oracle overlay (setSequencerUptimeFeed and
 *     setOracleConfig) on the timelock. No bypass: phase `execute` runs them after the delay (seed-local.sh
 *     advances anvil time with evm_increaseTime);
 *   - phase `state` drives the mock feeds: FEED_STATE = fresh | stale | invalid | reverting | deviate | seq-down |
 *     seq-up | seq-recent.
 * @dev It refuses any chain other than 31337. The default keys are anvil's public deterministic dev keys. Never use
 *      them on a real network.
 */
contract SeedLocal is Script {
    using Slot0Library for Slot0;

    // anvil deterministic dev keys (public, local only): account 0 = seeder, 2 = proposer, 3 = executor
    uint256 internal constant ANVIL_PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 internal constant ANVIL_PK2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant ANVIL_PK3 = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 public constant SEQUENCER_GRACE = 3600;
    uint32 public constant FEED_HEARTBEAT = 3600;
    uint16 public constant DEVIATION_ALPHA_BPS = 5000;
    uint16 public constant DEADBAND_BPS = 30;
    uint16 public constant MAX_DEVIATION_BPS = 1000;
    uint24 public constant FALLBACK_FEE_PIPS = 3000;
    int24 internal constant CL_TICK = 80040; // ≈ 2,992 mDAI per mWETH, multiple of 60
    uint256 public constant STABLE_A = 100;

    bytes32 public constant SALT_SEQ = keccak256("SeedLocal:setSequencerUptimeFeed");
    bytes32 public constant SALT_ORACLE = keccak256("SeedLocal:setOracleConfig");

    struct Addrs {
        address poolManager;
        address positionManager;
        address lvrPlugin;
        address antiJITPlugin;
        address timelock;
    }

    struct Seeded {
        address weth;
        address dai;
        address usdc;
        address priceFeed;
        address sequencerFeed;
        PoolKey clamm;
        PoolKey clammLvr;
        PoolKey clammAntiJit;
        PoolKey stable;
        PoolKey bin;
        bytes seqCall;
        bytes oracleCall;
    }

    error LocalOnly(uint256 chainId);

    // ------------------------------------------------------------------ entry points

    function run() external {
        if (block.chainid != 31337) revert LocalOnly(block.chainid);
        string memory phase = vm.envOr("SEED_PHASE", string("seed"));
        string memory outPath = vm.envOr("SEED_OUT", string("deployments/local-seed.json"));
        if (_eq(phase, "seed")) {
            Addrs memory a = Addrs({
                poolManager: vm.envAddress("POOL_MANAGER"),
                positionManager: vm.envAddress("POSITION_MANAGER"),
                lvrPlugin: vm.envAddress("LVR_PLUGIN"),
                antiJITPlugin: vm.envAddress("ANTIJIT_PLUGIN"),
                timelock: vm.envAddress("TIMELOCK")
            });
            vm.startBroadcast(vm.envOr("SEEDER_PK", ANVIL_PK0));
            Seeded memory s = seed(a);
            vm.stopBroadcast();
            uint256 delay = SupaTimelock(payable(a.timelock)).minDelay();
            vm.startBroadcast(vm.envOr("PROPOSER_PK", ANVIL_PK2));
            SupaTimelock(payable(a.timelock)).schedule(a.lvrPlugin, 0, s.seqCall, bytes32(0), SALT_SEQ, delay);
            SupaTimelock(payable(a.timelock)).schedule(a.lvrPlugin, 0, s.oracleCall, bytes32(0), SALT_ORACLE, delay);
            vm.stopBroadcast();
            _write(outPath, a, s);
            console2.log("Seeded. Governance ops scheduled; run phase `execute` after", delay, "seconds");
        } else if (_eq(phase, "execute")) {
            string memory j = vm.readFile(outPath);
            address tl = vm.parseJsonAddress(j, ".timelock");
            address lvr = vm.parseJsonAddress(j, ".lvrPlugin");
            vm.startBroadcast(vm.envOr("EXECUTOR_PK", ANVIL_PK3));
            SupaTimelock(payable(tl))
                .execute(lvr, 0, vm.parseJsonBytes(j, ".calls.setSequencerUptimeFeed"), 0, SALT_SEQ);
            SupaTimelock(payable(tl)).execute(lvr, 0, vm.parseJsonBytes(j, ".calls.setOracleConfig"), 0, SALT_ORACLE);
            vm.stopBroadcast();
            console2.log("LVR oracle overlay + sequencer feed wired via timelock");
        } else if (_eq(phase, "state")) {
            string memory j = vm.readFile(outPath);
            vm.startBroadcast(vm.envOr("SEEDER_PK", ANVIL_PK0));
            setFeedState(
                vm.parseJsonAddress(j, ".priceFeed"),
                vm.parseJsonAddress(j, ".sequencerFeed"),
                vm.parseJsonAddress(j, ".poolManager"),
                PoolId.wrap(vm.parseJsonBytes32(j, ".pools.clammLvr.id")),
                vm.envOr("FEED_STATE", string("fresh")),
                vm.envOr("FEED_PARAM", uint256(0))
            );
            vm.stopBroadcast();
        } else {
            revert("SEED_PHASE must be seed | execute | state");
        }
    }

    // ------------------------------------------------------------------ seeding (also driven by tests)

    function seed(Addrs memory a) public returns (Seeded memory s) {
        if (block.chainid != 31337) revert LocalOnly(block.chainid);
        address me = _sender();
        s.weth = address(new TestMintableERC20("Mock Wrapped Ether", "mWETH", 18, me, 1e30));
        s.dai = address(new TestMintableERC20("Mock Dai", "mDAI", 18, me, 1e30));
        s.usdc = address(new TestMintableERC20("Mock USD Coin", "mUSDC", 6, me, 1e18));
        _approve(s.weth, a.positionManager);
        _approve(s.dai, a.positionManager);
        _approve(s.usdc, a.positionManager);

        IPoolManager pm = IPoolManager(a.poolManager);
        (address w0, address w1) = s.weth < s.dai ? (s.weth, s.dai) : (s.dai, s.weth);
        // pool price token1/token0: want mDAI per mWETH ≈ 1.0001^CL_TICK
        int24 t = s.weth < s.dai ? CL_TICK : -CL_TICK;
        uint160 sqrtP = TickMathLib.getSqrtRatioAtTick(t);

        s.clamm = _key(w0, w1, 3000, 60, address(0), CurveType.CLAMM);
        s.clammLvr = _key(w0, w1, 3000, 60, a.lvrPlugin, CurveType.CLAMM);
        s.clammAntiJit = _key(w0, w1, 3000, 60, a.antiJITPlugin, CurveType.CLAMM);
        pm.initialize(s.clamm, sqrtP, "");
        pm.initialize(s.clammLvr, sqrtP, "");
        pm.initialize(s.clammAntiJit, sqrtP, "");
        _mint(a.positionManager, s.clamm, t - 6000, t + 6000, 1e21, me);
        _mint(a.positionManager, s.clammLvr, t - 6000, t + 6000, 1e21, me);
        _mint(a.positionManager, s.clammAntiJit, t - 6000, t + 6000, 1e21, me);

        // STABLE mUSDC/mDAI at the 1:1 peg in human units (raw price 1e12 or 1e-12), A = 100, tickSpacing 1.
        (address s0, address s1) = s.usdc < s.dai ? (s.usdc, s.dai) : (s.dai, s.usdc);
        uint160 pegSqrtP = s.usdc < s.dai ? uint160(1e6 * 2 ** 96) : uint160(uint256(2 ** 96) / 1e6);
        s.stable = _key(s0, s1, 100, 1, address(0), CurveType.STABLE_AMM);
        pm.initializeWithParams(s.stable, pegSqrtP, abi.encode(STABLE_A), "");
        _mint(a.positionManager, s.stable, 0, 0, 1_000_000e18, me); // first deposit: 1M normalised token0 units

        // BIN mWETH/mDAI, bin step 25, 21 bins centred on the active bin.
        s.bin = _key(w0, w1, 3000, 25, address(0), CurveType.BIN_AMM);
        pm.initialize(s.bin, sqrtP, "");
        int24 active = pm.getSlot0(s.bin.toId()).tick();
        _mint(a.positionManager, s.bin, active - 10, active + 10, 1e20, me);

        // Feeds: the price feed is "token1 per token0" in human units at 8 decimals, synced to the pool.
        s.priceFeed = address(new MockChainlinkAggregator(8, "mock token1 / token0", _poolPrice1e8(pm, s.clammLvr)));
        s.sequencerFeed = address(new MockSequencerUptimeFeed());

        s.seqCall = abi.encodeCall(
            LVRShieldPlugin.setSequencerUptimeFeed, (IAggregatorV3(s.sequencerFeed), uint32(SEQUENCER_GRACE))
        );
        s.oracleCall = abi.encodeCall(
            LVRShieldPlugin.setOracleConfig,
            (
                s.clammLvr,
                IAggregatorV3(s.priceFeed),
                false,
                FEED_HEARTBEAT,
                DEVIATION_ALPHA_BPS,
                DEADBAND_BPS,
                MAX_DEVIATION_BPS,
                FALLBACK_FEE_PIPS
            )
        );
    }

    /// @notice Drive mock feed states. `param`: stale → age seconds (default heartbeat + 1); deviate → bps
    ///         (default 200); seq-recent → seconds since restart (default 600); invalid → uses answer 0.
    function setFeedState(
        address priceFeed,
        address sequencerFeed,
        address poolManager,
        PoolId lvrPool,
        string memory state,
        uint256 param
    ) public {
        MockChainlinkAggregator f = MockChainlinkAggregator(priceFeed);
        MockSequencerUptimeFeed q = MockSequencerUptimeFeed(sequencerFeed);
        if (_eq(state, "fresh")) {
            f.setReverting(false);
            f.setFresh(_poolPrice1e8Id(IPoolManager(poolManager), lvrPool));
        } else if (_eq(state, "stale")) {
            f.setStale(param == 0 ? uint256(FEED_HEARTBEAT) + 1 : param);
        } else if (_eq(state, "invalid")) {
            f.setInvalid(0);
        } else if (_eq(state, "reverting")) {
            f.setReverting(true);
        } else if (_eq(state, "deviate")) {
            int256 p = _poolPrice1e8Id(IPoolManager(poolManager), lvrPool);
            f.setFresh(p + p * int256(param == 0 ? 200 : param) / 10_000);
        } else if (_eq(state, "seq-down")) {
            q.setDown();
        } else if (_eq(state, "seq-up")) {
            q.setUp(SEQUENCER_GRACE + 1 days);
        } else if (_eq(state, "seq-recent")) {
            q.setUp(param == 0 ? 600 : param);
        } else {
            revert("FEED_STATE unknown");
        }
    }

    // ------------------------------------------------------------------ helpers

    function _key(address c0, address c1, uint24 fee, int24 spacing, address plugin, CurveType ct)
        internal
        pure
        returns (PoolKey memory)
    {
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: fee,
            tickSpacing: spacing,
            plugin: plugin,
            curveType: ct
        });
    }

    function _mint(address posm, PoolKey memory key, int24 lo, int24 hi, uint128 liquidity, address to) internal {
        ISupaPositionManager(posm)
            .mint(
                ISupaPositionManager.MintParams({
                    poolKey: key,
                    tickLower: lo,
                    tickUpper: hi,
                    liquidity: liquidity,
                    amount0Max: type(uint128).max,
                    amount1Max: type(uint128).max,
                    recipient: to,
                    deadline: block.timestamp + 1 hours,
                    hookData: "",
                    payWithClaims: false
                })
            );
    }

    function _approve(address token, address spender) internal {
        TestMintableERC20(token).approve(spender, type(uint256).max);
    }

    function _poolPrice1e8(IPoolManager pm, PoolKey memory key) internal view returns (int256) {
        return _poolPrice1e8Id(pm, key.toId());
    }

    /// @dev Raw token1/token0 price × 1e8 (both mock tokens of the LVR pool have 18 decimals).
    function _poolPrice1e8Id(IPoolManager pm, PoolId id) internal view returns (int256) {
        uint256 sp = pm.getSlot0(id).sqrtPriceX96();
        return int256(FullMathLib.mulDiv(sp * sp, 1e8, 1 << 192));
    }

    /// @dev Inside forge script broadcast, msg.sender of calls made by this contract is the broadcaster; when a
    ///      test calls seed() directly, the script contract itself is the actor.
    function _sender() internal view returns (address) {
        (VmSafe.CallerMode mode, address broadcaster,) = vm.readCallers();
        if (mode == VmSafe.CallerMode.Broadcast || mode == VmSafe.CallerMode.RecurrentBroadcast) return broadcaster;
        return address(this);
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _keyJson(string memory obj, PoolKey memory k) internal returns (string memory) {
        vm.serializeBytes32(obj, "id", PoolId.unwrap(k.toId()));
        vm.serializeAddress(obj, "currency0", Currency.unwrap(k.currency0));
        vm.serializeAddress(obj, "currency1", Currency.unwrap(k.currency1));
        vm.serializeUint(obj, "fee", k.fee);
        vm.serializeInt(obj, "tickSpacing", k.tickSpacing);
        vm.serializeAddress(obj, "plugin", k.plugin);
        return vm.serializeUint(obj, "curveType", uint8(k.curveType));
    }

    function _write(string memory path, Addrs memory a, Seeded memory s) internal {
        string memory pools = "pools";
        vm.serializeString(pools, "clamm", _keyJson("p_clamm", s.clamm));
        vm.serializeString(pools, "clammLvr", _keyJson("p_lvr", s.clammLvr));
        vm.serializeString(pools, "clammAntiJit", _keyJson("p_jit", s.clammAntiJit));
        vm.serializeString(pools, "stable", _keyJson("p_stable", s.stable));
        string memory poolsJson = vm.serializeString(pools, "bin", _keyJson("p_bin", s.bin));
        string memory calls = "calls";
        vm.serializeBytes(calls, "setSequencerUptimeFeed", s.seqCall);
        string memory callsJson = vm.serializeBytes(calls, "setOracleConfig", s.oracleCall);
        string memory root = "root";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeAddress(root, "poolManager", a.poolManager);
        vm.serializeAddress(root, "positionManager", a.positionManager);
        vm.serializeAddress(root, "lvrPlugin", a.lvrPlugin);
        vm.serializeAddress(root, "antiJITPlugin", a.antiJITPlugin);
        vm.serializeAddress(root, "timelock", a.timelock);
        vm.serializeAddress(root, "mWETH", s.weth);
        vm.serializeAddress(root, "mDAI", s.dai);
        vm.serializeAddress(root, "mUSDC", s.usdc);
        vm.serializeAddress(root, "priceFeed", s.priceFeed);
        vm.serializeAddress(root, "sequencerFeed", s.sequencerFeed);
        vm.serializeBytes32(root, "saltSequencer", SALT_SEQ);
        vm.serializeBytes32(root, "saltOracle", SALT_ORACLE);
        vm.serializeString(root, "calls", callsJson);
        string memory out = vm.serializeString(root, "pools", poolsJson);
        vm.writeJson(out, path);
    }
}
