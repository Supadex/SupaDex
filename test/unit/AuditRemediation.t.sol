// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {SupaVault} from "../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../contract/core/SupaPoolManager.sol";
import {CLAMMEngine} from "../../contract/core/engines/CLAMMEngine.sol";
import {StableAMMEngine} from "../../contract/core/engines/StableAMMEngine.sol";
import {SupaPositionManager} from "../../contract/periphery/SupaPositionManager.sol";
import {PositionNFTDescriptor} from "../../contract/periphery/PositionNFTDescriptor.sol";
import {ISupaPositionManager} from "../../contract/interfaces/ISupaPositionManager.sol";
import {IPoolManager} from "../../contract/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "../../contract/interfaces/IUnlockCallback.sol";
import {PoolKey, CurveType} from "../../contract/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "../../contract/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "../../contract/types/Currency.sol";
import {BalanceDelta} from "../../contract/types/BalanceDelta.sol";
import {PoolErrors} from "../../contract/errors/PoolErrors.sol";
import {SecurityTestSetup} from "../helpers/SecurityTestSetup.sol";

contract AuditToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "allow");
            allowance[from][msg.sender] = allowed - amount;
        }
        require(balanceOf[from] >= amount, "bal");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Contract NFT owner with no receive/fallback. Plain ETH transfers revert.
contract RejectsPlainEth {
    /// @dev Mint refunds unused ETH. Allow that, and reject the later principal push.
    bool public acceptEth;

    receive() external payable {
        require(acceptEth, "no plain eth");
    }

    function mint(SupaPositionManager pm, ISupaPositionManager.MintParams calldata params, uint256 value)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity)
    {
        acceptEth = true;
        (tokenId, liquidity,,) = pm.mint{value: value}(params);
        acceptEth = false;
    }

    function exit(SupaPositionManager pm, uint256 tokenId, uint128 liquidity, address recipient, bool receiveAsClaims)
        external
    {
        pm.decreaseLiquidity(
            ISupaPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 days,
                hookData: "",
                recipient: recipient,
                receiveAsClaims: receiveAsClaims
            })
        );
    }

    function burn(SupaPositionManager pm, uint256 tokenId) external {
        pm.burn(tokenId);
    }

    function approveToken(AuditToken token, address spender) external {
        token.approve(spender, type(uint256).max);
    }
}

contract PoolUser is IUnlockCallback {
    using CurrencyLibrary for Currency;

    SupaVault public vault;
    SupaPoolManager public manager;
    AuditToken public t0;
    AuditToken public t1;

    constructor(SupaVault _vault, SupaPoolManager _manager, AuditToken _t0, AuditToken _t1) {
        vault = _vault;
        manager = _manager;
        t0 = _t0;
        t1 = _t1;
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        (uint8 action, PoolKey memory key, int256 liquidityDelta) = abi.decode(data, (uint8, PoolKey, int256));
        if (action == 0) {
            (BalanceDelta delta,) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: -120, tickUpper: 120, liquidityDelta: liquidityDelta, salt: 0
                }),
                ""
            );
            _settle(key, delta);
        }
        return "";
    }

    function modify(PoolKey memory key, int256 liquidityDelta) external {
        vault.unlock(abi.encode(uint8(0), key, liquidityDelta));
    }

    function _settle(PoolKey memory key, BalanceDelta delta) internal {
        _leg(key.currency0, delta.amount0());
        _leg(key.currency1, delta.amount1());
    }

    function _leg(Currency currency, int128 amount) internal {
        if (amount > 0) {
            AuditToken token = AuditToken(Currency.unwrap(currency));
            vault.sync(currency);
            token.transfer(address(vault), uint256(uint128(amount)));
            vault.settle(currency);
        } else if (amount < 0) {
            vault.take(currency, address(this), uint256(uint128(-amount)));
        }
    }
}

contract AuditRemediationTest is Test {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_1_1 = 79228162514264337593543950336;

    function _pair() internal returns (AuditToken a, AuditToken b, Currency c0, Currency c1) {
        AuditToken x = new AuditToken("A", "A");
        AuditToken y = new AuditToken("B", "B");
        if (address(x) > address(y)) (x, y) = (y, x);
        return (x, y, Currency.wrap(address(x)), Currency.wrap(address(y)));
    }

    function _stack()
        internal
        returns (SupaVault vault, SupaPoolManager manager, SupaPositionManager pos, AuditToken t0, AuditToken t1)
    {
        vault = new SupaVault(address(this));
        (manager,,,) = SecurityTestSetup.deployManagerWithEngines(vault);
        vault.setPoolManager(address(manager), true);
        SecurityTestSetup.installEmptyWhitelist(manager, address(this));
        pos = new SupaPositionManager(manager, vault, address(new PositionNFTDescriptor()));
        (t0, t1,,) = _pair();
    }

    /// L-02: the first StableSwap LP through the position manager can exit fully and burn the NFT.
    function test_stableFirstLpFullExitBurnsNft() public {
        (SupaVault vault, SupaPoolManager manager, SupaPositionManager pos, AuditToken t0, AuditToken t1) = _stack();
        vault;
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 100,
            tickSpacing: 1,
            plugin: address(0),
            curveType: CurveType.STABLE_AMM
        });
        manager.initializeWithParams(key, SQRT_1_1, abi.encode(uint256(100)), "");

        uint128 shares = 10_000;
        t0.mint(address(this), shares);
        t1.mint(address(this), shares);
        t0.approve(address(pos), type(uint256).max);
        t1.approve(address(pos), type(uint256).max);

        (uint256 tokenId, uint128 credited,,) = pos.mint(
            ISupaPositionManager.MintParams({
                poolKey: key,
                tickLower: 0,
                tickUpper: 0,
                liquidity: shares,
                amount0Max: shares,
                amount1Max: shares,
                recipient: address(this),
                deadline: block.timestamp + 1 days,
                hookData: "",
                payWithClaims: false
            })
        );

        assertEq(credited, shares - 1000, "MINIMUM_LIQUIDITY is not part of the NFT");
        assertEq(pos.positions(tokenId).liquidity, shares - 1000);

        pos.decreaseLiquidity(
            ISupaPositionManager.DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: credited,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp + 1 days,
                hookData: "",
                recipient: address(this),
                receiveAsClaims: false
            })
        );
        assertEq(pos.positions(tokenId).liquidity, 0);
        pos.burn(tokenId);
        vm.expectRevert();
        pos.ownerOf(tokenId);

        StableAMMEngine stable = StableAMMEngine(address(manager.stableEngine()));
        assertEq(stable.getLiquidity(key.toId()), 1000, "only the locked minimum remains");
    }

    /// L-04: protocol fee above 25% is rejected.
    function test_protocolFeeCeiling() public {
        (, SupaPoolManager manager,, AuditToken t0, AuditToken t1) = _stack();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(key, SQRT_1_1, "");
        vm.expectRevert(abi.encodeWithSelector(PoolErrors.InvalidProtocolFee.selector, uint24(250_001)));
        manager.setProtocolFee(key, 250_001);
        manager.setProtocolFee(key, 250_000);
    }

    /// L-05: a contract that cannot receive plain ETH can still withdraw, via claims or an EOA recipient.
    function test_contractOwnerCanWithdrawNativePrincipal() public {
        (SupaVault vault, SupaPoolManager manager, SupaPositionManager pos,, AuditToken t1) = _stack();
        Currency eth = Currency.wrap(address(0));
        Currency tok = Currency.wrap(address(t1));
        // Native must be currency0.
        if (Currency.unwrap(tok) == address(0)) return;
        PoolKey memory key = PoolKey({
            currency0: eth, currency1: tok, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
        });
        manager.initialize(key, SQRT_1_1, "");

        RejectsPlainEth rejecter = new RejectsPlainEth();
        t1.mint(address(rejecter), 100 ether);
        vm.deal(address(rejecter), 100 ether);
        vm.prank(address(rejecter));
        rejecter.approveToken(t1, address(pos));

        ISupaPositionManager.MintParams memory mintParams = ISupaPositionManager.MintParams({
            poolKey: key,
            tickLower: -120,
            tickUpper: 120,
            liquidity: 1 ether,
            amount0Max: 10 ether,
            amount1Max: 10 ether,
            recipient: address(rejecter),
            deadline: block.timestamp + 1 days,
            hookData: "",
            payWithClaims: false
        });
        vm.prank(address(rejecter));
        (uint256 tokenId, uint128 liquidity) = rejecter.mint(pos, mintParams, 10 ether);
        assertGt(liquidity, 0);
        assertEq(pos.ownerOf(tokenId), address(rejecter));

        vm.prank(address(rejecter));
        vm.expectRevert();
        rejecter.exit(pos, tokenId, liquidity, address(0), false);

        address payable eoa = payable(address(0xE0A));
        uint256 eoaBefore = eoa.balance;
        vm.prank(address(rejecter));
        rejecter.exit(pos, tokenId, liquidity, eoa, false);
        assertGt(eoa.balance, eoaBefore, "principal ETH delivered to the EOA");
        assertEq(pos.positions(tokenId).liquidity, 0);

        // A second position exits as claims, including the native leg, then the NFT burns.
        vm.prank(address(rejecter));
        (uint256 tokenId2, uint128 liquidity2) = rejecter.mint(pos, mintParams, 10 ether);
        vm.prank(address(rejecter));
        rejecter.exit(pos, tokenId2, liquidity2, address(rejecter), true);
        assertGt(vault.balanceOf(address(rejecter), eth.toId()), 0, "native principal parked as a claim");
        assertEq(pos.positions(tokenId2).liquidity, 0);
        vm.prank(address(rejecter));
        rejecter.burn(pos, tokenId2);
    }

    /// M-01: withdrawing one pool does not reduce the other pool's recorded reserves, and the other pool can exit.
    function test_twoPoolsDoNotShareReservePot() public {
        (SupaVault vault, SupaPoolManager manager,, AuditToken t0, AuditToken t1) = _stack();
        PoolKey memory a = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            fee: 3000,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        PoolKey memory b = PoolKey({
            currency0: a.currency0,
            currency1: a.currency1,
            fee: 500,
            tickSpacing: 60,
            plugin: address(0),
            curveType: CurveType.CLAMM
        });
        manager.initialize(a, SQRT_1_1, "");
        manager.initialize(b, SQRT_1_1, "");

        PoolUser user = new PoolUser(vault, manager, t0, t1);
        t0.mint(address(user), 1_000 ether);
        t1.mint(address(user), 1_000 ether);
        user.modify(a, int256(100 ether));
        user.modify(b, int256(100 ether));

        uint256 b0 = manager.poolReserves(b.toId(), b.currency0);
        uint256 b1 = manager.poolReserves(b.toId(), b.currency1);
        assertGt(b0, 0);
        assertGt(b1, 0);

        user.modify(a, -int256(100 ether));
        assertEq(manager.poolReserves(b.toId(), b.currency0), b0, "pool B token0 pot untouched");
        assertEq(manager.poolReserves(b.toId(), b.currency1), b1, "pool B token1 pot untouched");

        user.modify(b, -int256(100 ether));
        // Rounding can leave 1 wei in the pot; the position itself is fully removed.
        assertLe(manager.poolReserves(b.toId(), b.currency0), 1);
        assertLe(manager.poolReserves(b.toId(), b.currency1), 1);
    }
}
