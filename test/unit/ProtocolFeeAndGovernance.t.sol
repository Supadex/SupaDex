// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ProtocolFeeLib} from "../../contract/libraries/ProtocolFeeLib.sol";
import {SupaRoles} from "../../contract/governance/SupaRoles.sol";
import {PluginWhitelist} from "../../contract/governance/PluginWhitelist.sol";
import {PluginWhitelistErrors} from "../../contract/errors/PluginWhitelistErrors.sol";

contract ProtocolFeeAndGovernanceTest is Test {
    function test_splitFeeZeroProtocol() public pure {
        (uint256 lp, uint256 proto) = ProtocolFeeLib.splitFee(1000, 0);
        assertEq(lp, 1000);
        assertEq(proto, 0);
    }

    function test_splitFeeQuarterIsTheCeiling() public pure {
        (uint256 lp, uint256 proto) = ProtocolFeeLib.splitFee(1000, 250_000);
        assertEq(lp, 750);
        assertEq(proto, 250);
    }

    function test_splitFeeAboveCeilingIsCappedAtTwentyFivePercent() public pure {
        // 100% and 50% inputs must not confiscate the LP fee. The ceiling is 25%.
        (uint256 lpFull, uint256 protoFull) = ProtocolFeeLib.splitFee(1000, 1_000_000);
        assertEq(lpFull, 750);
        assertEq(protoFull, 250);
        (uint256 lpHalf, uint256 protoHalf) = ProtocolFeeLib.splitFee(1000, 500_000);
        assertEq(lpHalf, 750);
        assertEq(protoHalf, 250);
        assertEq(ProtocolFeeLib.MAX_PROTOCOL_FEE, 250_000);
    }

    function test_rolesOperator() public {
        SupaRoles roles = new SupaRoles(address(this), address(0xBEEF));
        assertTrue(roles.isOperator(address(0xBEEF)));
        roles.setOperator(address(0xCAFE), true);
        assertTrue(roles.isOperator(address(0xCAFE)));
        roles.setOperator(address(0xCAFE), false);
        assertFalse(roles.isOperator(address(0xCAFE)));
    }

    function test_pluginWhitelist() public {
        address[] memory initial = new address[](1);
        initial[0] = address(0x1111);
        PluginWhitelist wl = new PluginWhitelist(address(this), initial);
        assertTrue(wl.isPluginWhitelisted(address(0)));
        assertTrue(wl.isPluginWhitelisted(address(0x1111)));
        assertFalse(wl.isPluginWhitelisted(address(0x2222)));
        wl.setPluginWhitelisted(address(0x2222), true);
        assertTrue(wl.isPluginWhitelisted(address(0x2222)));
    }
}
