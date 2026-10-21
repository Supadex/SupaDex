// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ChainIds} from "../../contract/libraries/ChainIds.sol";
import {SupaTimelock} from "../../contract/governance/SupaTimelock.sol";
import {DeployEnvironment} from "../../script/DeployEnvironment.sol";

/// @notice Edith R3 (ADR-0009 / ADR-0010 conditions): one chain-id source of truth, fail closed.
contract ChainIdsTest is Test {
    SupaTimelock tl;

    function setUp() external {
        address[] memory p = new address[](1);
        address[] memory e = new address[](1);
        address[] memory c = new address[](1);
        (p[0], e[0], c[0]) = (address(0xA1), address(0xA2), address(0xA3));
        tl = new SupaTimelock(1 hours, address(0xAD), p, e, c);
    }

    function _deployTestChain(uint256 id) internal pure returns (bool) {
        DeployEnvironment.Kind k = DeployEnvironment.classify(id);
        return k == DeployEnvironment.Kind.LOCAL || k == DeployEnvironment.Kind.TESTNET;
    }

    /// The timelock's test-chain list and the deploy script's LOCAL/TESTNET classification agree on every id.
    function testFuzz_timelockAndDeployScriptAgree(uint256 id) public view {
        assertEq(tl.isTestChain(id), _deployTestChain(id));
        assertEq(tl.isTestChain(id), ChainIds.isTestChain(id));
    }

    /// Exhaustive over every id either list has ever named, plus the removed ones.
    function test_timelockAndDeployScriptAgree_knownIds() public view {
        uint256[28] memory ids = [
            uint256(1), 10, 56, 97, 100, 137, 250, 324, 1101, 1337, 5000, 8453, 10143, 17000, 31337, 42161, 43114,
            59144, 80002, 81457, 84532, 421614, 534352, 560048, 11155111, 11155420, 5, 999_999_999
        ];
        for (uint256 i; i < ids.length; ++i) {
            assertEq(tl.isTestChain(ids[i]), _deployTestChain(ids[i]), "lists disagree");
        }
    }

    function test_removedIds_areNotTestChains() public view {
        assertFalse(tl.isTestChain(10143), "Monad testnet is value-bearing");
        assertFalse(tl.isTestChain(1337), "geth-dev 1337 fails closed");
        assertEq(uint8(DeployEnvironment.classify(10143)), uint8(DeployEnvironment.Kind.UNKNOWN));
        assertEq(uint8(DeployEnvironment.classify(1337)), uint8(DeployEnvironment.Kind.UNKNOWN));
        assertTrue(DeployEnvironment.valueBearing(DeployEnvironment.classify(1337), 1337));
        assertTrue(tl.isTestChain(31337) && tl.isTestChain(11155111) && tl.isTestChain(84532));
    }

    /// No production chain is a test chain; no test chain is classified production.
    function test_productionAndTestDisjoint() public view {
        uint256[15] memory prod = [uint256(1), 10, 56, 137, 8453, 42161, 43114, 324, 59144, 534352, 100, 250, 1101, 5000, 81457];
        for (uint256 i; i < prod.length; ++i) {
            assertEq(uint8(DeployEnvironment.classify(prod[i])), uint8(DeployEnvironment.Kind.PRODUCTION));
            assertFalse(tl.isTestChain(prod[i]));
        }
    }

    /// Sequencer requirement fails closed: only the explicit L1 / local allowlist is exempt.
    function test_sequencer_rollupsRequireFeed() public pure {
        uint256[12] memory l2 =
            [uint256(1101), 5000, 81457, 8453, 84532, 10, 11155420, 42161, 421614, 59144, 534352, 324];
        for (uint256 i; i < l2.length; ++i) {
            assertTrue(ChainIds.requiresSequencerFeed(l2[i]), "rollup must require an uptime feed");
        }
        uint256[12] memory l1 = [uint256(1), 11155111, 17000, 560048, 56, 97, 43114, 100, 250, 137, 80002, 31337];
        for (uint256 i; i < l1.length; ++i) {
            assertFalse(ChainIds.requiresSequencerFeed(l1[i]), "explicit L1 / local allowlist");
        }
        assertTrue(ChainIds.requiresSequencerFeed(10143), "Monad not exempt");
        assertTrue(ChainIds.requiresSequencerFeed(1337), "geth-dev not exempt");
    }

    /// Any id outside the 12-entry exemption allowlist requires a feed (fail closed for unknown chains).
    function testFuzz_sequencer_unknownRequiresFeed(uint256 id) public pure {
        vm.assume(
            id != 1 && id != 11155111 && id != 17000 && id != 560048 && id != 56 && id != 97 && id != 43114
                && id != 100 && id != 250 && id != 137 && id != 80002 && id != 31337
        );
        assertTrue(ChainIds.requiresSequencerFeed(id));
    }
}
