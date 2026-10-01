// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISupaPositionManager} from "../interfaces/ISupaPositionManager.sol";
import {IPoolManager} from "../interfaces/IPoolManager.sol";
import {IVault} from "../interfaces/IVault.sol";
import {IUnlockCallback} from "../interfaces/IUnlockCallback.sol";
import {IPeripheryEvents} from "../events/IPeripheryEvents.sol";
import {PeripheryPayments} from "./base/PeripheryPayments.sol";
import {Multicall} from "./base/Multicall.sol";
import {PoolKey} from "../types/PoolKey.sol";
import {PoolId} from "../types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {BalanceDelta} from "../types/BalanceDelta.sol";
import {PeripheryErrors} from "../errors/PeripheryErrors.sol";
import {VaultErrors} from "../errors/VaultErrors.sol";
import {ERC721} from "solady/tokens/ERC721.sol";

interface IPositionNFTDescriptor {
    function tokenURI(uint256 tokenId, ISupaPositionManager.PositionInfo memory pos)
        external
        view
        returns (string memory);
}

/**
 * @title SupaPositionManager
 * @notice Production-grade ERC-721 tokenized liquidity manager for SupaDex pools.
 */
contract SupaPositionManager is
    ISupaPositionManager,
    IUnlockCallback,
    IPeripheryEvents,
    PeripheryPayments,
    Multicall,
    ERC721
{
    using CurrencyLibrary for Currency;

    /**
     * @dev Internal action discriminators for unlock callback routing.
     */
    enum Action {
        MINT,
        INCREASE,
        DECREASE,
        COLLECT,
        SYNC_FEES
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    IPoolManager public immutable override poolManager;

    /**
     * @dev External on-chain SVG/JSON renderer (keeps this contract under EIP-170).
     */
    IPositionNFTDescriptor public immutable descriptor;

    /**
     * @dev Auto-incrementing NFT token counter.
     */
    uint256 private _nextTokenId = 1;

    /**
     * @dev Storage mapping from token ID to position details.
     */
    mapping(uint256 => PositionInfo) private _positions;

    constructor(IPoolManager _poolManager, IVault _vaultContract, address _descriptor)
        PeripheryPayments(_vaultContract)
    {
        poolManager = _poolManager;
        descriptor = IPositionNFTDescriptor(_descriptor);
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function vault() public view override(ISupaPositionManager, PeripheryPayments) returns (IVault) {
        return _vault;
    }

    /**
     * @dev Modifier verifying that unlock callback originates strictly from the authorized Vault.
     */
    modifier onlyVault() {
        if (msg.sender != address(_vault)) revert VaultErrors.Unauthorized();
        _;
    }

    /**
     * @inheritdoc ERC721
     */
    function name() public pure override returns (string memory) {
        return "SupaDex Concentrated LP Position";
    }

    /**
     * @inheritdoc ERC721
     */
    function symbol() public pure override returns (string memory) {
        return "SUPA-POS";
    }

    /**
     * @inheritdoc ERC721
     * @dev Delegates to PositionNFTDescriptor for Obsidian Lattice metadata.
     */
    function tokenURI(uint256 id) public view override returns (string memory) {
        if (!_exists(id)) revert TokenDoesNotExist();
        return descriptor.tokenURI(id, _positions[id]);
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function positions(uint256 tokenId) external view override returns (PositionInfo memory) {
        if (!_exists(tokenId)) revert PeripheryErrors.PositionNotFound(tokenId);
        return _positions[tokenId];
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function mint(MintParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.liquidity == 0) revert PeripheryErrors.ZeroLiquidity();
        tokenId = _nextTokenId++;

        bytes memory result = _vault.unlock(abi.encode(Action.MINT, msg.sender, tokenId, params));

        (liquidity, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));

        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function increaseLiquidity(IncreaseLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        if (params.liquidity == 0) revert PeripheryErrors.ZeroLiquidity();
        if (!_isApprovedOrOwner(msg.sender, params.tokenId)) revert PeripheryErrors.Unauthorized();

        bytes memory result = _vault.unlock(abi.encode(Action.INCREASE, msg.sender, params));

        (liquidity, amount0, amount1) = abi.decode(result, (uint128, uint256, uint256));

        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        override
        checkDeadline(params.deadline)
        returns (uint256 amount0, uint256 amount1)
    {
        if (params.liquidity == 0) revert PeripheryErrors.ZeroLiquidity();
        if (!_isApprovedOrOwner(msg.sender, params.tokenId)) revert PeripheryErrors.Unauthorized();

        bytes memory result = _vault.unlock(abi.encode(Action.DECREASE, msg.sender, params));

        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function collect(CollectParams calldata params)
        external
        payable
        override
        returns (uint256 amount0, uint256 amount1)
    {
        if (!_isApprovedOrOwner(msg.sender, params.tokenId)) {
            revert PeripheryErrors.Unauthorized();
        }

        bytes memory result = _vault.unlock(abi.encode(Action.COLLECT, msg.sender, params));

        (amount0, amount1) = abi.decode(result, (uint256, uint256));

        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function syncFees(uint256 tokenId) external payable override returns (uint256 fees0, uint256 fees1) {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert PeripheryErrors.Unauthorized();

        bytes memory result = _vault.unlock(abi.encode(Action.SYNC_FEES, msg.sender, tokenId));
        (fees0, fees1) = abi.decode(result, (uint256, uint256));

        if (address(this).balance > 0) {
            this.refundETH();
        }
    }

    /**
     * @inheritdoc ISupaPositionManager
     */
    function burn(uint256 tokenId) external payable override {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert PeripheryErrors.Unauthorized();
        PositionInfo storage pos = _positions[tokenId];
        if (pos.liquidity != 0 || pos.tokensOwed0 != 0 || pos.tokensOwed1 != 0) {
            revert PeripheryErrors.Unauthorized();
        }

        address owner = ownerOf(tokenId);
        _burn(tokenId);
        delete _positions[tokenId];

        emit PositionBurned(tokenId, owner);
    }

    /**
     * @inheritdoc IUnlockCallback
     */
    function unlockCallback(bytes calldata data) external override onlyVault returns (bytes memory) {
        Action action = abi.decode(data, (Action));

        if (action == Action.MINT) {
            (, address payer, uint256 tokenId, MintParams memory params) =
                abi.decode(data, (Action, address, uint256, MintParams));
            (uint128 liquidity, uint256 amount0, uint256 amount1) = _handleMint(payer, tokenId, params);
            return abi.encode(liquidity, amount0, amount1);
        } else if (action == Action.INCREASE) {
            (, address payer, IncreaseLiquidityParams memory params) =
                abi.decode(data, (Action, address, IncreaseLiquidityParams));
            (uint128 liquidity, uint256 amount0, uint256 amount1) = _handleIncrease(payer, params);
            return abi.encode(liquidity, amount0, amount1);
        } else if (action == Action.DECREASE) {
            (, address payer, DecreaseLiquidityParams memory params) =
                abi.decode(data, (Action, address, DecreaseLiquidityParams));
            (uint256 amount0, uint256 amount1) = _handleDecrease(payer, params);
            return abi.encode(amount0, amount1);
        } else if (action == Action.SYNC_FEES) {
            (, , uint256 tokenId) = abi.decode(data, (Action, address, uint256));
            (uint256 fees0, uint256 fees1) = _accrueFees(tokenId);
            if (fees0 > 0 || fees1 > 0) {
                emit FeesSynced(tokenId, fees0, fees1);
            }
            return abi.encode(fees0, fees1);
        } else {
            (, address payer, CollectParams memory params) = abi.decode(data, (Action, address, CollectParams));
            (uint256 amount0, uint256 amount1) = _handleCollect(payer, params);
            return abi.encode(amount0, amount1);
        }
    }

    /**
     * @dev Pokes the curve engine with a zero liquidity delta to credit accrued swap fees.
     *      Mints ERC-6909 claims to this contract so the vault flash delta settles.
     */
    function _accrueFees(uint256 tokenId) internal returns (uint256 fees0, uint256 fees1) {
        PositionInfo storage pos = _positions[tokenId];
        if (pos.liquidity == 0) return (0, 0);

        IPoolManager.ModifyLiquidityParams memory modParams = IPoolManager.ModifyLiquidityParams({
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            liquidityDelta: 0,
            salt: bytes32(tokenId)
        });

        (, BalanceDelta feesAccrued) = poolManager.modifyLiquidity(pos.poolKey, modParams, "");
        (fees0, fees1) = _creditFees(pos, feesAccrued);
    }

    /**
     * @dev Records fees into tokensOwed and parks them as vault claims (settles flash delta).
     */
    function _creditFees(PositionInfo storage pos, BalanceDelta feesAccrued)
        internal
        returns (uint256 fees0, uint256 fees1)
    {
        if (feesAccrued.amount0() > 0) {
            fees0 = uint256(int256(feesAccrued.amount0()));
            pos.tokensOwed0 += uint128(fees0);
            _take(pos.poolKey.currency0, address(this), fees0, true);
        }
        if (feesAccrued.amount1() > 0) {
            fees1 = uint256(int256(feesAccrued.amount1()));
            pos.tokensOwed1 += uint128(fees1);
            _take(pos.poolKey.currency1, address(this), fees1, true);
        }
    }

    /**
     * @dev Internal handler for minting a new position NFT.
     */
    function _handleMint(address payer, uint256 tokenId, MintParams memory params)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        IPoolManager.ModifyLiquidityParams memory modParams = IPoolManager.ModifyLiquidityParams({
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidityDelta: int256(uint256(params.liquidity)),
            salt: bytes32(tokenId)
        });

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(params.poolKey, modParams, params.hookData);

        amount0 = uint256(uint128(callerDelta.amount0()));
        amount1 = uint256(uint128(callerDelta.amount1()));

        if (amount0 > params.amount0Max || amount1 > params.amount1Max) {
            revert PeripheryErrors.SlippageExceeded(params.amount0Max, amount0);
        }

        // Settle token inputs with Vault (physical ERC-20 or ERC-6909 claims)
        _pay(params.poolKey.currency0, payer, amount0, params.payWithClaims);
        _pay(params.poolKey.currency1, payer, amount1, params.payWithClaims);

        _positions[tokenId] = PositionInfo({
            poolKey: params.poolKey,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: params.liquidity,
            feeGrowthInside0LastX128: 0,
            feeGrowthInside1LastX128: 0,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        _mint(params.recipient, tokenId);
        liquidity = params.liquidity;

        emit PositionMinted(
            tokenId,
            params.recipient,
            params.poolKey.toId(),
            params.tickLower,
            params.tickUpper,
            liquidity,
            amount0,
            amount1
        );
    }

    /**
     * @dev Internal handler for increasing position liquidity.
     */
    function _handleIncrease(address payer, IncreaseLiquidityParams memory params)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        PositionInfo storage pos = _positions[params.tokenId];

        IPoolManager.ModifyLiquidityParams memory modParams = IPoolManager.ModifyLiquidityParams({
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            liquidityDelta: int256(uint256(params.liquidity)),
            salt: bytes32(params.tokenId)
        });

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            poolManager.modifyLiquidity(pos.poolKey, modParams, params.hookData);

        amount0 = uint256(uint128(callerDelta.amount0()));
        amount1 = uint256(uint128(callerDelta.amount1()));

        if (amount0 > params.amount0Max || amount1 > params.amount1Max) {
            revert PeripheryErrors.SlippageExceeded(params.amount0Max, amount0);
        }

        // Record any accrued fees into tokensOwed (park as vault claims)
        _creditFees(pos, feesAccrued);

        _pay(pos.poolKey.currency0, payer, amount0, params.payWithClaims);
        _pay(pos.poolKey.currency1, payer, amount1, params.payWithClaims);

        pos.liquidity += params.liquidity;
        liquidity = pos.liquidity;

        emit LiquidityIncreased(params.tokenId, params.liquidity, amount0, amount1);
    }

    /**
     * @dev Internal handler for decreasing position liquidity.
     */
    function _handleDecrease(address payer, DecreaseLiquidityParams memory params)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PositionInfo storage pos = _positions[params.tokenId];
        if (pos.liquidity < params.liquidity) revert PeripheryErrors.ZeroLiquidity();

        IPoolManager.ModifyLiquidityParams memory modParams = IPoolManager.ModifyLiquidityParams({
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            liquidityDelta: -int256(uint256(params.liquidity)),
            salt: bytes32(params.tokenId)
        });

        (BalanceDelta callerDelta, BalanceDelta feesAccrued) =
            poolManager.modifyLiquidity(pos.poolKey, modParams, params.hookData);

        amount0 = uint256(uint128(-callerDelta.amount0()));
        amount1 = uint256(uint128(-callerDelta.amount1()));

        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert PeripheryErrors.SlippageExceeded(params.amount0Min, amount0);
        }

        // Record accrued fees (park as vault claims)
        _creditFees(pos, feesAccrued);

        pos.liquidity -= params.liquidity;

        // Deliver withdrawn principal liquidity to caller
        _take(pos.poolKey.currency0, payer, amount0, false);
        _take(pos.poolKey.currency1, payer, amount1, false);

        emit LiquidityDecreased(params.tokenId, params.liquidity, amount0, amount1);
    }

    /**
     * @dev Internal handler for collecting owed fees.
     */
    function _handleCollect(
        address,
        /* payer */
        CollectParams memory params
    )
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        // Sync accrued swap fees into tokensOwed before withdrawing.
        _accrueFees(params.tokenId);

        PositionInfo storage pos = _positions[params.tokenId];

        amount0 = params.amount0Max > pos.tokensOwed0 ? pos.tokensOwed0 : params.amount0Max;
        amount1 = params.amount1Max > pos.tokensOwed1 ? pos.tokensOwed1 : params.amount1Max;

        if (amount0 > 0) {
            pos.tokensOwed0 -= uint128(amount0);
            // Fees were parked as claims; burn then take ERC-20 to recipient.
            _vault.burn(pos.poolKey.currency0, amount0);
            _take(pos.poolKey.currency0, params.recipient, amount0, false);
        }
        if (amount1 > 0) {
            pos.tokensOwed1 -= uint128(amount1);
            _vault.burn(pos.poolKey.currency1, amount1);
            _take(pos.poolKey.currency1, params.recipient, amount1, false);
        }

        emit FeesCollected(params.tokenId, params.recipient, amount0, amount1);
    }
}
