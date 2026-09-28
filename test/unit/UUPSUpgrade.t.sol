// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {VaultErrors} from "../../contract/errors/VaultErrors.sol";

contract SupaVaultV2 is SupaVault {
    constructor(address _owner) SupaVault(_owner) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UUPSUpgradeTest is Test {
    SupaVault public vaultImplementation;
    SupaVaultV2 public vaultV2Implementation;
    address public proxy;
    SupaVault public vault;

    address public owner = address(0xAAAA);
    address public stranger = address(0xBBBB);

    function setUp() external {
        vaultImplementation = new SupaVault(owner);
        vaultV2Implementation = new SupaVaultV2(owner);

        // Deploy ERC1967 proxy pointing to V1 implementation
        proxy = LibClone.deployERC1967(address(vaultImplementation));
        vault = SupaVault(payable(proxy));

        // Initialize owner on the proxy instance
        vault.initialize(owner);
    }

    function test_proxyStateAndAccess() public {
        assertEq(vault.owner(), owner);

        // Stranger cannot upgrade
        vm.prank(stranger);
        vm.expectRevert(VaultErrors.Unauthorized.selector);
        vault.upgradeToAndCall(address(vaultV2Implementation), "");

        // Owner upgrades
        vm.prank(owner);
        vault.upgradeToAndCall(address(vaultV2Implementation), "");

        // Verify V2 behavior
        SupaVaultV2 vaultV2 = SupaVaultV2(payable(proxy));
        assertEq(vaultV2.version(), 2);
        assertEq(vaultV2.owner(), owner);
    }
}
