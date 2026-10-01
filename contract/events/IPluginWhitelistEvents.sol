// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IPluginWhitelistEvents
 * @notice Events for the plugin whitelist registry.
 */
interface IPluginWhitelistEvents {
    event PluginWhitelisted(address indexed plugin, bool whitelisted);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
}
