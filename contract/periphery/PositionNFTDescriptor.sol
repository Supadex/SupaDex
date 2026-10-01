// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaPositionManager} from "../interfaces/ISupaPositionManager.sol";
import {NFTDescriptorLib} from "../libraries/NFTDescriptorLib.sol";

/**
 * @title PositionNFTDescriptor
 * @notice External ERC-721 metadata renderer for SupaDex position NFTs.
 * @dev Kept separate from SupaPositionManager to stay under EIP-170 contract size.
 */
contract PositionNFTDescriptor {
    /**
     * @notice Builds on-chain tokenURI JSON + Obsidian Lattice SVG for a position.
     */
    function tokenURI(uint256 tokenId, ISupaPositionManager.PositionInfo memory pos)
        external
        view
        returns (string memory)
    {
        return NFTDescriptorLib.tokenURI(tokenId, pos);
    }
}
