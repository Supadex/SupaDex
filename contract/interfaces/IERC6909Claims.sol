// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IERC6909Claims
 * @notice Minimal interface for standard ERC-6909 multi-token claims within the SupaDex Vault.
 */
interface IERC6909Claims {
    /**
     * @notice Emitted when tokens are transferred.
     */
    event Transfer(
        address caller, address indexed sender, address indexed receiver, uint256 indexed id, uint256 amount
    );

    /**
     * @notice Emitted when an operator is set.
     */
    event OperatorSet(address indexed owner, address indexed operator, bool approved);

    /**
     * @notice Emitted when an approval is granted.
     */
    event Approval(address indexed owner, address indexed spender, uint256 indexed id, uint256 amount);

    /**
     * @notice Returns the balance of an account for a given token id (Currency address cast to uint256).
     */
    function balanceOf(address account, uint256 id) external view returns (uint256);

    /**
     * @notice Returns the allowance granted to a spender for a given token id.
     */
    function allowance(address owner, address spender, uint256 id) external view returns (uint256);

    /**
     * @notice Returns whether an operator is approved for all token ids for an owner.
     */
    function isOperator(address owner, address operator) external view returns (bool);

    /**
     * @notice Transfers tokens to a receiver.
     */
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool);

    /**
     * @notice Transfers tokens from a sender to a receiver using allowance or operator permission.
     */
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool);

    /**
     * @notice Sets allowance for a spender for a given token id.
     */
    function approve(address spender, uint256 id, uint256 amount) external returns (bool);

    /**
     * @notice Sets or revokes operator approval for all token ids.
     */
    function setOperator(address operator, bool approved) external returns (bool);
}
