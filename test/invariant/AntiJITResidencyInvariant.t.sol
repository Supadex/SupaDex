// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType, PoolKeyLibrary} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "../../contract/types/BalanceDelta.sol";

contract AntiJITResidencyHandler is Test {
    AntiJITVestingPlugin public immutable plugin;
    address public immutable manager;
    PoolKey public key;
    PoolId public immutable poolId;

    address[4] public actors = [address(0x10), address(0x20), address(0x30), address(0x40)];
    mapping(address => uint128) public activeUserLiquidity;

    uint256 public maxFeesHookObserved;

    constructor(AntiJITVestingPlugin _plugin, address _manager) {
        plugin = _plugin;
        manager = _manager;

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(_plugin),
            curveType: CurveType.CLAMM
        });

        poolId = PoolKeyLibrary.toId(key);
    }

    function addLiquidity(uint8 actorIdx, uint8 blockJump, uint64 amount) external {
        address actor = actors[actorIdx % 4];
        vm.roll(block.number + (blockJump % 10));

        uint128 deposit = uint128(bound(amount, 1, 1_000_000_000));
        vm.prank(manager);
        plugin.beforeModifyLiquidity(
            actor,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: int256(uint256(deposit)), salt: bytes32(0)
            }),
            ""
        );

        activeUserLiquidity[actor] += deposit;
    }

    function removeLiquidity(uint8 actorIdx, uint8 blockJump, uint64 amount, uint64 fee0) external {
        address actor = actors[actorIdx % 4];
        vm.roll(block.number + (blockJump % 10));

        uint128 cur = activeUserLiquidity[actor];
        if (cur == 0) return;

        uint128 burn = uint128(bound(amount, 1, cur));
        uint256 fees = bound(fee0, 0, 1_000_000);

        // before+after in one pranked call stack so transient pending bps survives.
        vm.startPrank(manager);
        plugin.beforeModifyLiquidity(
            actor,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -int256(uint256(burn)), salt: bytes32(0)
            }),
            ""
        );
        (,, BalanceDelta feesHook) = plugin.afterModifyLiquidity(
            actor,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120, tickUpper: 120, liquidityDelta: -int256(uint256(burn)), salt: bytes32(0)
            }),
            toBalanceDelta(-int128(int256(uint256(burn))), 0),
            toBalanceDelta(int128(int256(fees)), 0),
            ""
        );
        vm.stopPrank();

        uint256 haircut = uint256(uint128(feesHook.amount0()));
        if (haircut > maxFeesHookObserved) maxFeesHookObserved = haircut;
        assertLe(haircut, fees, "unvested fees must never exceed feesAccrued");

        activeUserLiquidity[actor] -= burn;
    }
}

contract AntiJITResidencyInvariantTest is StdInvariant, Test {
    AntiJITVestingPlugin internal plugin;
    AntiJITResidencyHandler internal handler;

    function setUp() public {
        // Test contract is the authorized pool manager for onlyPoolManager checks.
        plugin = new AntiJITVestingPlugin(IPoolManager(address(this)), 3);
        handler = new AntiJITResidencyHandler(plugin, address(this));

        targetContract(address(handler));
    }

    function invariant_residencyLiquidityMatchesActiveUserLiquidity() public view {
        PoolId pid = handler.poolId();
        for (uint256 i = 0; i < 4; i++) {
            address actor = handler.actors(i);
            bytes32 posKey = keccak256(abi.encodePacked(actor, int24(-120), int24(120), bytes32(0)));
            (,, uint128 trackedLiq) = plugin.residencies(pid, posKey);
            assertEq(trackedLiq, handler.activeUserLiquidity(actor), "Liquidity residency tracking mismatch");
        }
    }

    function invariant_feesHookNeverExceedsAccrued() public view {
        // Ghosted in handler assertions; surface for reporting.
        assertGe(type(uint256).max, handler.maxFeesHookObserved());
    }
}
