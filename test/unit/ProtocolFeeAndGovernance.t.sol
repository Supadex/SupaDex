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

    function test_splitFeeHalf() public pure {
        (uint256 lp, uint256 proto) = ProtocolFeeLib.splitFee(1000, 500_000);
        assertEq(lp, 500);
        assertEq(proto, 500);
    }

    function test_splitFeeFullProtocol() public pure {
        (uint256 lp, uint256 proto) = ProtocolFeeLib.splitFee(1000, 1_000_000);
        assertEq(lp, 0);
        assertEq(proto, 1000);
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
