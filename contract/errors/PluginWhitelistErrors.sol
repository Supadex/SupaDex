// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title PluginWhitelistErrors
 * @notice Custom errors for the plugin whitelist registry.
 */
library PluginWhitelistErrors {
    error Unauthorized();
    error ZeroAddress();
    error PluginNotWhitelisted(address plugin);
}
