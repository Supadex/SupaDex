// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPluginWhitelistEvents} from "../events/IPluginWhitelistEvents.sol";

/**
 * @title IPluginWhitelist
 * @notice Registry of plugins permitted for PoolKey.plugin at initialize.
 */
interface IPluginWhitelist is IPluginWhitelistEvents {
    function owner() external view returns (address);
    function isPluginWhitelisted(address plugin) external view returns (bool);
    function setPluginWhitelisted(address plugin, bool whitelisted) external;
    function transferOwnership(address newOwner) external;
}
