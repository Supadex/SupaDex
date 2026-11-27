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
import {RevertClassifier, RevertClassifyingHandler} from "./RevertClassifier.sol";

contract LVRDynamicFeeHandler is Test, RevertClassifyingHandler {
    using PoolIdLibrary for PoolKey;

    LVRShieldPlugin public immutable plugin;
    VolatilityTWAPOracle public immutable oracle;
    PoolKey public key;

    uint24 public latestCalculatedFee;

    constructor() {
        plugin = new LVRShieldPlugin(IPoolManager(address(this)));
        oracle = VolatilityTWAPOracle(address(plugin.oracle()));

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
        vm.prank(address(plugin));
        // T-6: was a bare `catch {}` swallowing every oracle failure. Oracle errors
        // (NotOracleWriter / OracleNotInitialized / InvalidCardinality / ...) are
        // UNEXPECTED here — a failed write means the fee is computed from stale ticks.
        try oracle.write(key.toId(), uint32(block.timestamp), newTick, 1_000_000) {}
        catch (bytes memory err) {
            _classify(err, RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT, "oracleWrite");
            return;
        }

        // T-6: a reverted beforeSwap must not update the tracked fee.
        try plugin.beforeSwap(
            address(this), key, IPoolManager.SwapParams(true, int256(uint256(swapAmount % 1_000_000_000 + 1)), 0), ""
        ) returns (
            bytes4, uint24 overrideFee
        ) {
            latestCalculatedFee = overrideFee;
        } catch (bytes memory err) {
            _classify(err, RevertClassifier.CTX_ECONOMIC | RevertClassifier.CTX_INPUT, "beforeSwap");
        }
    }
}

contract LVRDynamicFeeInvariantTest is StdInvariant, Test {
    using PoolIdLibrary for PoolKey;

    LVRDynamicFeeHandler internal handler;

    function setUp() public {
        handler = new LVRDynamicFeeHandler();
        targetContract(address(handler));
    }

    /// @notice T-6: only classified expected reverts may occur; anything else fails the run.
    function invariant_noUnexpectedReverts() public view {
        assertEq(handler.unexpectedReverts(), 0, "unexpected revert in LVR handler");
    }

    function invariant_dynamicFeeAlwaysWithinBounds() public view {
        uint24 fee = handler.latestCalculatedFee();
        // Plugin clamps within pool min/max (defaults 1..100_000); DynamicFeeLib also floors at MIN_FEE.
        assertGe(fee, 1, "Fee below plugin min floor");
        assertLe(fee, DynamicFeeLib.MAX_FEE, "Fee above MAX_FEE cap");
    }
}
