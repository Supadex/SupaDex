// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LVRShieldPlugin} from "../../contract/plugins/native/LVRShieldPlugin.sol";
import {VolatilityTWAPOracle} from "../../contract/plugins/native/VolatilityTWAPOracle.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency} from "../../contract/types/Currency.sol";
import {DynamicFeeLib} from "../../contract/libraries/DynamicFeeLib.sol";

contract LVRDynamicFeeHandler is Test {
    using PoolIdLibrary for PoolKey;

    LVRShieldPlugin public immutable plugin;
    VolatilityTWAPOracle public immutable oracle;
    PoolKey public key;

    uint24 public latestCalculatedFee;

    constructor(VolatilityTWAPOracle _oracle) {
        oracle = _oracle;
        plugin = new LVRShieldPlugin(IPoolManager(address(this)), _oracle);

        key = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(plugin),
            curveType: CurveType.CLAMM
        });

        plugin.afterInitialize(address(this), key, 100, 0);
        latestCalculatedFee = 3000;
    }

    function executeFuzzedSwap(uint16 timeJump, int16 tickJump, uint128 swapAmount) external {
        uint32 jump = uint32(bound(timeJump, 0, 86400));
        vm.warp(block.timestamp + jump);

        int24 newTick = int24(bound(int256(tickJump), -50000, 50000));
        try oracle.write(key.toId(), uint32(block.timestamp), newTick, 1_000_000) {} catch {}

        (, uint24 overrideFee) = plugin.beforeSwap(
            address(this),
            key,
            IPoolManager.SwapParams(true, int256(uint256(swapAmount % 1_000_000_000 + 1)), 0),
            ""
        );

        latestCalculatedFee = overrideFee;
    }
}

contract LVRDynamicFeeInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    VolatilityTWAPOracle internal oracle;
    LVRDynamicFeeHandler internal handler;

    function setUp() public {
        oracle = new VolatilityTWAPOracle();
        handler = new LVRDynamicFeeHandler(oracle);

        targetContract(address(handler));
    }

    function invariant_dynamicFeeAlwaysWithinBounds() public view {
        uint24 fee = handler.latestCalculatedFee();
        assertGe(fee, DynamicFeeLib.MIN_FEE, "Fee below MIN_FEE floor");
        assertLe(fee, DynamicFeeLib.MAX_FEE, "Fee above MAX_FEE cap");
    }
}
