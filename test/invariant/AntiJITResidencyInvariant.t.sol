// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {AntiJITVestingPlugin} from "../../contract/plugins/native/AntiJITVestingPlugin.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType, PoolKeyLibrary} from "../../contract/types/PoolKey.sol";
import {PoolId} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";

contract AntiJITResidencyHandler is Test {
    AntiJITVestingPlugin public immutable plugin;
    PoolKey public key;
    PoolId public immutable poolId;

    address[4] public actors = [address(0x10), address(0x20), address(0x30), address(0x40)];
    mapping(address => uint128) public activeUserLiquidity;

    constructor(AntiJITVestingPlugin _plugin) {
        plugin = _plugin;

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
        plugin.beforeModifyLiquidity(
            actor,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: int256(uint256(deposit)),
                salt: bytes32(0)
            }),
            ""
        );

        activeUserLiquidity[actor] += deposit;
    }

    function removeLiquidity(uint8 actorIdx, uint8 blockJump, uint64 amount) external {
        address actor = actors[actorIdx % 4];
        vm.roll(block.number + (blockJump % 10));

        uint128 cur = activeUserLiquidity[actor];
        if (cur == 0) return;

        uint128 burn = uint128(bound(amount, 1, cur));
        plugin.beforeModifyLiquidity(
            actor,
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: -int256(uint256(burn)),
                salt: bytes32(0)
            }),
            ""
        );

        activeUserLiquidity[actor] -= burn;
    }
}

contract AntiJITResidencyInvariantTest is StdInvariant, Test {
    AntiJITVestingPlugin internal plugin;
    AntiJITResidencyHandler internal handler;

    function setUp() public {
        plugin = new AntiJITVestingPlugin(IPoolManager(address(this)), 3);
        handler = new AntiJITResidencyHandler(plugin);

        targetContract(address(handler));
    }

    function invariant_residencyLiquidityMatchesActiveUserLiquidity() public view {
        PoolId pid = handler.poolId();
        for (uint256 i = 0; i < 4; i++) {
            address actor = handler.actors(i);
            bytes32 posKey = keccak256(abi.encodePacked(actor, int24(-120), int24(120), bytes32(0)));
            (, , uint128 trackedLiq) = plugin.residencies(pid, posKey);
            assertEq(trackedLiq, handler.activeUserLiquidity(actor), "Liquidity residency tracking mismatch");
        }
    }
}
