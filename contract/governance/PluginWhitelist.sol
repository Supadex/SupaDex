// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPluginWhitelist} from "../interfaces/IPluginWhitelist.sol";
import {PluginWhitelistErrors} from "../errors/PluginWhitelistErrors.sol";

/**
 * @title PluginWhitelist
 * @notice Timelock-owned allowlist of pool plugins; address(0) is always permitted (no plugin).
 */
contract PluginWhitelist is IPluginWhitelist {
    address public override owner;
    mapping(address => bool) private _whitelisted;

    modifier onlyOwner() {
        if (msg.sender != owner) revert PluginWhitelistErrors.Unauthorized();
        _;
    }

    constructor(address initialOwner, address[] memory initialPlugins) {
        if (initialOwner == address(0)) revert PluginWhitelistErrors.ZeroAddress();
        owner = initialOwner;
        uint256 len = initialPlugins.length;
        for (uint256 i; i < len;) {
            address plugin = initialPlugins[i];
            if (plugin == address(0)) revert PluginWhitelistErrors.ZeroAddress();
            _whitelisted[plugin] = true;
            emit PluginWhitelisted(plugin, true);
            unchecked {
                ++i;
            }
        }
    }

    function isPluginWhitelisted(address plugin) external view override returns (bool) {
        if (plugin == address(0)) return true;
        return _whitelisted[plugin];
    }

    function setPluginWhitelisted(address plugin, bool whitelisted) external override onlyOwner {
        if (plugin == address(0)) revert PluginWhitelistErrors.ZeroAddress();
        _whitelisted[plugin] = whitelisted;
        emit PluginWhitelisted(plugin, whitelisted);
    }

    function transferOwnership(address newOwner) external override onlyOwner {
        if (newOwner == address(0)) revert PluginWhitelistErrors.ZeroAddress();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }
}
