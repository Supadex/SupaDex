// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StableAMMEngineTest} from "../../unit/StableAMMEngine.t.sol";
import {PoolKey} from "../../../contract/types/PoolKey.sol";
import {PoolIdLibrary} from "../../../contract/types/PoolId.sol";
import {PoolErrors} from "../../../contract/errors/PoolErrors.sol";
import {console2} from "forge-std/Test.sol";

// PORT (remediation-3): Jexi rem2 stable probes, inverted to assert the fixes for APUS-SUPADEX-020 (no panic) and
// APUS-SUPADEX-022 / Edith 7-B (a guardian cannot stop a ramp that is not active).
contract JexiRem2StableTest is StableAMMEngineTest {
    using PoolIdLibrary for PoolKey;

    /// Edith's counterexample, replayed deterministically.
    function test_edith_015_counterexample() public {
        this.testFuzz_015_noSolverFreeze(5879, 999999999999999999999999, false, false);
    }

    /// APUS-SUPADEX-020 committed counterexamples (Jexi, clean persist dir, 10k runs): seed 2 at run 1,241 and seed
    /// 31337 at run 4,212. Both panicked 0x11 at 192664b and must now pass (named revert or success).
    function test_020_seed2_counterexample() public {
        this.testFuzz_015_noSolverFreeze(1403, 999999999999999999999999, false, false);
    }

    function test_020_seed31337_counterexample() public {
        this.testFuzz_015_noSolverFreeze(43, 999999999999999999999999, false, false);
    }

    /// Deterministic sweep: exact-out of ~the whole reserve, across A and both directions; count panic(0x11).
    function test_exactOutNearFullReserve_sweep() public {
        uint256 panics;
        uint256 classified;
        uint256 ok;
        uint256 other;
        bytes4 panicSel = bytes4(keccak256("Panic(uint256)"));
        uint16[6] memory As = [uint16(1), 10, 100, 1000, 5879, 10000];
        for (uint256 i; i < As.length; i++) {
            for (uint256 z; z < 2; z++) {
                for (uint256 j; j < 8; j++) {
                    uint256 amt = 1_000_000 ether - (10 ** (j * 3)); // 1e24 - {1,1e3,...,1e21}
                    try this.testFuzz_015_noSolverFreeze(As[i], uint96(amt), z == 0, false) {
                        ok++;
                    } catch (bytes memory err) {
                        if (bytes4(err) == panicSel) panics++;
                        else if (bytes4(err) == bytes4(keccak256("Error(string)")) || err.length == 0) other++;
                        else classified++;
                    }
                }
            }
        }
        console2.log("exact-out near full reserve: ok / panic(assert-fail) / other:", ok, panics, other);
        console2.log("classified:", classified);
        assertEq(panics, 0, "020: exact-out near full reserve must never panic"); // PORT
        assertEq(other, 0, "020: only named custom errors"); // PORT
    }

    /// Edith 7-B / APUS-SUPADEX-022, PORT inverted: a guardian stopRampA with no active ramp reverts
    /// (StableNoActiveRamp) and changes nothing, so governance ramps are never blocked.
    function test_edith_7B_guardianStopBlocksGovernanceRamp_INVERTED() public {
        _seed(key, SQRT_1_1, 1_000_000 ether);
        uint256 t = vm.getBlockTimestamp();
        uint256 blocked;
        for (uint256 day = 1; day <= 5; day++) {
            t += 1 days - 60;
            vm.warp(t);
            vm.prank(GUARDIAN);
            (,,,, uint256 fut) = engine.getAmplification(key.toId());
            vm.expectRevert(abi.encodeWithSelector(PoolErrors.StableNoActiveRamp.selector, fut));
            engine.stopRampA(key); // no ramp active
            t += 120;
            vm.warp(t);
            uint256 snap = vm.snapshotState();
            try engine.rampA(key, 200, t + 2 days) {}
            catch {
                blocked++;
            }
            vm.revertToState(snap);
        }
        console2.log("governance rampA attempts blocked by daily guardian stop (of 5):", blocked);
        assertEq(blocked, 0, "022: guardian must not block governance ramps");
    }
}
