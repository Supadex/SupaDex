// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "./IPoolManager.sol";
import {IVault} from "./IVault.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";

/**
 * @title ISupaPositionManager
 * @notice Interface for tokenized ERC-721 liquidity positions in SupaDex.
 */
interface ISupaPositionManager {
    /**
     * @notice Details of an individual position NFT.
     */
    struct PositionInfo {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 feeGrowthInside0LastX128;
        uint256 feeGrowthInside1LastX128;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    /**
     * @notice Parameters for minting a new position NFT.
     */
    struct MintParams {
        PoolKey poolKey;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        address recipient;
        uint256 deadline;
        bytes hookData;
        bool payWithClaims;
    }

    /**
     * @notice Parameters for increasing liquidity in an existing position NFT.
     */
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        uint256 deadline;
        bytes hookData;
        bool payWithClaims;
    }

    /**
     * @notice Parameters for decreasing liquidity in an existing position NFT.
     */
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
        bytes hookData;
    }

    /**
     * @notice Parameters for collecting accumulated fees.
     */
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /**
     * @notice Returns the PoolManager contract instance.
     */
    function poolManager() external view returns (IPoolManager);

    /**
     * @notice Returns the Vault contract instance.
     */
    function vault() external view returns (IVault);

    /**
     * @notice Returns position details for a given NFT token ID.
     */
    function positions(uint256 tokenId) external view returns (PositionInfo memory);

    /**
     * @notice Mints a new position NFT and deposits liquidity.
     */
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Increases liquidity for an existing position NFT.
     */
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);

    /**
     * @notice Decreases liquidity for an existing position NFT.
     */
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Collects accumulated LP fee earnings.
     */
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /**
     * @notice Pokes the pool engine to sync accrued swap fees into tokensOwed without collecting.
     */
    function syncFees(uint256 tokenId) external payable returns (uint256 fees0, uint256 fees1);

    /**
     * @notice Burns an empty position NFT with zero remaining liquidity and zero tokens owed.
     */
    function burn(uint256 tokenId) external payable;
}
