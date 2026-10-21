// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Jexi probes: CLAMM exact-in dust and its effect on SupaRouter.exactInput (multi-hop).
import {Test, console2} from "forge-std/Test.sol";
import {JexiSupaDexTest, JToken, JFlashActor} from "../JexiSupaDex.t.sol";
import {IUnlockCallback} from "../../../contract/interfaces/IUnlockCallback.sol";
import {IPoolManager} from "../../../contract/interfaces/IPoolManager.sol";
import {SupaVault} from "../../../contract/core/SupaVault.sol";
import {SupaPoolManager} from "../../../contract/core/SupaPoolManager.sol";
import {ISupaRouter} from "../../../contract/interfaces/ISupaRouter.sol";
import {PoolKey, CurveType} from "../../../contract/types/PoolKey.sol";
import {Currency} from "../../../contract/types/Currency.sol";
import {BalanceDelta} from "../../../contract/types/BalanceDelta.sol";

contract JSwapProbe is IUnlockCallback {
    SupaVault public immutable vault;
    SupaPoolManager public immutable pm;
    int128 public lastIn;

    constructor(SupaVault v, SupaPoolManager m) {
        vault = v;
        pm = m;
    }

    function probe(PoolKey memory k, bool z, int256 amt) external returns (int128) {
        try vault.unlock(abi.encode(k, z, amt)) {}
        catch (bytes memory r) {
            // unlock reverts because we deliberately do not settle; decode delta from revert payload
            assembly {
                r := add(r, 4)
            }
            return abi.decode(r, (int128));
        }
        return 0;
    }

    error Report(int128 consumedIn);

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (PoolKey memory k, bool z, int256 amt) = abi.decode(data, (PoolKey, bool, int256));
        BalanceDelta d =
            pm.swap(k, IPoolManager.SwapParams({zeroForOne: z, amountSpecified: amt, sqrtPriceLimitX96: 0}), "");
        revert Report(z ? d.amount0() : d.amount1());
    }
}

contract JexiProbeTest is JexiSupaDexTest {
    function test_probe_exactInDustAndMultiHop() public {
        PoolKey memory k = _clammPool(address(0), -6000, 6000, 79228162514264337593543950336, 1e24);
        JSwapProbe p = new JSwapProbe(vault, pm);
        uint256 mism;
        for (uint256 i = 1; i <= 50; i++) {
            int256 amt = int256(uint256(keccak256(abi.encode(i))) % 1e20) + 1e12;
            int128 used = p.probe(k, i % 2 == 0, amt);
            if (int256(used) != amt) {
                mism++;
                if (mism <= 3) {
                    console2.log("specified vs consumed");
                    console2.logInt(amt);
                    console2.logInt(int256(used));
                }
            }
        }
        console2.log("exact-in swaps leaving unconsumed dust (of 50):", mism);

        // two-hop exactInput t0 -> t1 -> t2
        JToken c = new JToken("C");
        Currency cc = Currency.wrap(address(c));
        PoolKey memory k2;
        if (address(c) > address(t1)) {
            k2 = PoolKey({
                currency0: c1, currency1: cc, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            });
        } else {
            k2 = PoolKey({
                currency0: cc, currency1: c1, fee: 3000, tickSpacing: 60, plugin: address(0), curveType: CurveType.CLAMM
            });
        }
        pm.initialize(k2, 79228162514264337593543950336, "");
        JFlashActor lp = new JFlashActor(vault, pm);
        t1.mint(address(lp), 1e27);
        c.mint(address(lp), 1e27);
        lp.exec(_one(_op(0, k2, -6000, 6000, 1e24, false)));

        bytes memory path = abi.encodePacked(
            c0, uint24(3000), int24(60), address(0), uint8(0), c1, uint24(3000), int24(60), address(0), uint8(0), cc
        );
        uint256 ok;
        uint256 fail;
        for (uint256 i = 1; i <= 20; i++) {
            uint128 amt = uint128(uint256(keccak256(abi.encode("mh", i))) % 1e20) + 1e12;
            try router.exactInput(
                ISupaRouter.ExactInputParams({
                    path: path,
                    recipient: address(this),
                    amountIn: amt,
                    amountOutMinimum: 0,
                    payWithClaims: false,
                    receiveAsClaims: false,
                    deadline: block.timestamp
                })
            ) returns (
                uint256
            ) {
                ok++;
            } catch {
                fail++;
            }
        }
        console2.log("2-hop exactInput ok / reverted (of 20):", ok, fail);
    }
}
