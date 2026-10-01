// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base64} from "solady/utils/Base64.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ISupaPositionManager} from "../interfaces/ISupaPositionManager.sol";
import {Currency, CurrencyLibrary} from "../types/Currency.sol";
import {CurveType} from "../types/PoolKey.sol";
import {NFTSVGLib} from "./NFTSVGLib.sol";

interface IERC20Symbol {
    function symbol() external view returns (string memory);
}

/**
 * @title NFTDescriptorLib
 * @notice Builds ERC-721 `tokenURI` JSON + embedded Obsidian Lattice SVG for SupaDex positions.
 */
library NFTDescriptorLib {
    using CurrencyLibrary for Currency;
    using LibString for uint256;

    function tokenURI(uint256 tokenId, ISupaPositionManager.PositionInfo memory pos)
        internal
        view
        returns (string memory)
    {
        string memory symbol0 = _safeSymbol(pos.poolKey.currency0);
        string memory symbol1 = _safeSymbol(pos.poolKey.currency1);
        (string memory curveLabel, uint8 curveType) = _curveMeta(pos.poolKey.curveType);
        string memory feeLabel = _feeLabel(pos.poolKey.fee);

        string memory svg = NFTSVGLib.generateSVG(
            NFTSVGLib.SVGParams({
                tokenId: tokenId,
                symbol0: symbol0,
                symbol1: symbol1,
                curveLabel: curveLabel,
                curveType: curveType,
                feeLabel: feeLabel,
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                currency0: pos.poolKey.currency0.toAddress(),
                currency1: pos.poolKey.currency1.toAddress()
            })
        );

        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));

        string memory name_ = string.concat(
            "SupaDex ", curveLabel, " - ", symbol0, "/", symbol1, " #", tokenId.toString()
        );
        string memory description = string.concat(
            "SupaDex liquidity position NFT (",
            curveLabel,
            "). Fee ",
            feeLabel,
            ". On-chain Obsidian Lattice art generated from pool + tick state."
        );

        string memory json = string.concat(
            '{"name":"',
            name_,
            '","description":"',
            description,
            '","image":"',
            image,
            '","attributes":[',
            '{"trait_type":"Curve","value":"',
            curveLabel,
            '"},',
            '{"trait_type":"Fee","value":"',
            feeLabel,
            '"},',
            '{"trait_type":"Token0","value":"',
            symbol0,
            '"},',
            '{"trait_type":"Token1","value":"',
            symbol1,
            '"},',
            '{"trait_type":"Tick Lower","value":"',
            _int24ToString(pos.tickLower),
            '"},',
            '{"trait_type":"Tick Upper","value":"',
            _int24ToString(pos.tickUpper),
            '"},',
            '{"trait_type":"Liquidity","value":"',
            uint256(pos.liquidity).toString(),
            '"}',
            "]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _safeSymbol(Currency currency) private view returns (string memory) {
        if (currency.isNative()) return "ETH";
        address token = currency.toAddress();
        try IERC20Symbol(token).symbol() returns (string memory sym) {
            if (bytes(sym).length == 0) return _shortAddr(token);
            // Cap length for SVG/JSON safety
            bytes memory b = bytes(sym);
            if (b.length > 12) {
                bytes memory clipped = new bytes(12);
                for (uint256 i; i < 12; i++) {
                    clipped[i] = b[i];
                }
                return string(clipped);
            }
            return sym;
        } catch {
            return _shortAddr(token);
        }
    }

    function _shortAddr(address a) private pure returns (string memory) {
        return string.concat("0x", LibString.toHexStringNoPrefix(uint256(uint160(a)), 2));
    }

    function _curveMeta(CurveType curveType) private pure returns (string memory label, uint8 id) {
        if (curveType == CurveType.BIN_AMM) return ("BinAMM", 1);
        if (curveType == CurveType.STABLE_AMM) return ("StableAMM", 2);
        return ("CLAMM", 0);
    }

    function _feeLabel(uint24 fee) private pure returns (string memory) {
        // fee is hundredths of a bip: 3000 = 0.30%
        uint256 whole = uint256(fee) / 10000;
        uint256 frac = (uint256(fee) % 10000) / 100; // 2 decimals of percent
        if (frac < 10) {
            return string.concat(whole.toString(), ".0", frac.toString(), "%");
        }
        return string.concat(whole.toString(), ".", frac.toString(), "%");
    }

    function _int24ToString(int24 v) private pure returns (string memory) {
        if (v >= 0) return uint256(uint24(v)).toString();
        return string.concat("-", uint256(uint24(-v)).toString());
    }
}
