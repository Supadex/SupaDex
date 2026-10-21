// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Jexi: PoolManager/vault-level reproduction of Edith's E-1 (BIN fee-growth overflow price wall), zero capital.
import "../JexiSupaDex.t.sol";
import {PoolIdLibrary} from "../../../contract/types/PoolId.sol";

/// @notice APUS-SUPADEX-021 PoCs (Jexi, PoolManager + vault level), INVERTED for remediation-3: fee growth is now
///         unchecked (Uniswap semantics, wrap-around), so the zero-capital donate/poke loop can no longer build a
///         price wall. Original exploit-positive version: apus-ops/security-findings/supadex/tests/rem2/.
contract JexiRem2FeeGrowthTest is JexiSupaDexTest {
    using PoolIdLibrary for PoolKey;

    function _maxAmts() internal pure returns (uint256[] memory amts) {
        amts = new uint256[](3);
        amts[0] = uint256(uint128(type(int128).max));
        amts[1] = uint256(uint128(type(int128).max));
        amts[2] = 1;
    }

    function _try(JFlashActor a, PoolKey memory k, int256 amt, bool zeroForOne) internal returns (bool ok) {
        try a.exec(_one(_op(1, k, 0, 0, amt, zeroForOne))) {
            ok = true;
        } catch {}
    }

    function _binWallSetup() internal returns (PoolKey memory k, JDonateAdder att) {
        k = _key(CurveType.BIN_AMM, 3000, 10, address(0));
        pm.initialize(k, SQRT_1_1, "");
        att = new JDonateAdder(vault, pm);
        t1.mint(address(att), 1);
        t0.mint(address(att), 1);
        att.add(k, 0, 1); // 1 share in active bin 0
        att.setSide0(true);
        att.run(k, 0, _maxAmts()); // zero-capital donate/poke loop: must not revert, must not brick
    }

    function test_E1_binPriceWall_zeroCapital_PMLevel_INVERTED() public {
        (PoolKey memory k, JDonateAdder att) = _binWallSetup();
        assertLe(1 - t0.balanceOf(address(att)) + (1 - t1.balanceOf(address(att))), 2, "attacker spend is dust");
        JFlashActor honest = _actor(1e30);
        honest.exec(_one(_op(0, k, -64, -1, 1e24, false)));
        honest.exec(_one(_op(0, k, 1, 64, 1e24, false)));
        JFlashActor trader = _actor(1e30);
        assertTrue(_try(trader, k, 1e18, true), "021: zeroForOne 1e18 must succeed (no wall)");
        assertTrue(_try(trader, k, 1e22, true), "021: zeroForOne 1e22 must succeed (no wall)");
        assertTrue(_try(trader, k, 1e18, false), "oneForZero 1e18 succeeds");
    }

    function test_E1_clammSoleLP_wall_PMLevel_INVERTED() public {
        PoolKey memory k = _key(CurveType.CLAMM, 3000, 60, address(0));
        pm.initialize(k, SQRT_1_1, "");
        JDonateAdder att = new JDonateAdder(vault, pm);
        t0.mint(address(att), 1e18);
        t1.mint(address(att), 1e18);
        att.addClamm(k, -60, 60, 1);
        att.runClamm(k, -60, 60, _maxAmts()); // loop completes (wrap-around), no revert
        JFlashActor honest = _actor(1e30);
        honest.exec(_one(_op(0, k, 60, 6000, 1e24, false)));
        JFlashActor trader = _actor(1e30);
        assertTrue(_try(trader, k, 1e18, false), "021: CLAMM oneForZero through attacker-only range must succeed");
        honest.exec(_one(_op(0, k, -60, 60, 1e24, false)));
        assertTrue(_try(trader, k, 1e18, false), "after honest dilution succeeds");
        assertTrue(_try(trader, k, 1e18, true), "reverse direction succeeds");
    }
}

contract JDonateAdder is IUnlockCallback {
    SupaVault public immutable vault;
    SupaPoolManager public immutable pm;
    uint8 mode;
    bool public side0;

    function setSide0(bool v) external {
        side0 = v;
    }

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        pm = m;
    }

    function add(PoolKey memory k, int24 id, int256 shares) external {
        mode = 0;
        vault.unlock(abi.encode(k, id, id, shares, new uint256[](0)));
    }

    function addClamm(PoolKey memory k, int24 lo, int24 hi, int256 liq) external {
        mode = 0;
        vault.unlock(abi.encode(k, lo, hi, liq, new uint256[](0)));
    }

    function run(PoolKey memory k, int24 id, uint256[] memory amts) external {
        mode = 1;
        vault.unlock(abi.encode(k, id, id, int256(0), amts));
    }

    function runClamm(PoolKey memory k, int24 lo, int24 hi, uint256[] memory amts) external {
        mode = 1;
        vault.unlock(abi.encode(k, lo, hi, int256(0), amts));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory k, int24 lo, int24 hi, int256 liq, uint256[] memory amts) =
            abi.decode(data, (PoolKey, int24, int24, int256, uint256[]));
        if (mode == 0) {
            pm.modifyLiquidity(
                k, IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: liq, salt: 0}), ""
            );
        } else {
            for (uint256 i; i < amts.length; i++) {
                pm.donate(k, side0 ? amts[i] : 0, side0 ? 0 : amts[i], "");
                pm.modifyLiquidity(
                    k,
                    IPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: 0, salt: 0}),
                    ""
                );
            }
        }
        _net(k.currency0);
        _net(k.currency1);
        return "";
    }

    function _net(Currency c) internal {
        int256 d = vault.getCurrencyDelta(address(this), c);
        if (d < 0) {
            vault.sync(c);
            JToken(Currency.unwrap(c)).transfer(address(vault), uint256(-d));
            vault.settle(c);
        } else if (d > 0) {
            vault.take(c, address(this), uint256(d));
        }
    }
}
