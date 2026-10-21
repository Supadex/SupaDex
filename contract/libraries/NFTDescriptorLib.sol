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

    struct Labels {
        string symbol0;
        string symbol1;
        string curveLabel;
        uint8 curveType;
        string feeLabel;
    }

    function tokenURI(uint256 tokenId, ISupaPositionManager.PositionInfo memory pos)
        internal
        view
        returns (string memory)
    {
        Labels memory l;
        l.symbol0 = _safeSymbol(pos.poolKey.currency0);
        l.symbol1 = _safeSymbol(pos.poolKey.currency1);
        (l.curveLabel, l.curveType) = _curveMeta(pos.poolKey.curveType);
        l.feeLabel = _feeLabel(pos.poolKey.fee);

        string memory json = string.concat(
            _header(tokenId, l),
            _image(tokenId, pos, l),
            '","attributes":[',
            _attributes(l.curveLabel, l.feeLabel, l.symbol0, l.symbol1),
            _rangeAttributes(pos.tickLower, pos.tickUpper, pos.liquidity),
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _header(uint256 tokenId, Labels memory l) private pure returns (string memory) {
        return string.concat(
            '{"name":"SupaDex ',
            l.curveLabel,
            " - ",
            l.symbol0,
            "/",
            l.symbol1,
            " #",
            tokenId.toString(),
            '","description":"SupaDex liquidity position NFT (',
            l.curveLabel,
            "). Fee ",
            l.feeLabel,
            '. On-chain Obsidian Lattice art generated from pool + tick state.","image":"'
        );
    }

    function _image(uint256 tokenId, ISupaPositionManager.PositionInfo memory pos, Labels memory l)
        private
        pure
        returns (string memory)
    {
        string memory svg = NFTSVGLib.generateSVG(
            NFTSVGLib.SVGParams({
                tokenId: tokenId,
                symbol0: l.symbol0,
                symbol1: l.symbol1,
                curveLabel: l.curveLabel,
                curveType: l.curveType,
                feeLabel: l.feeLabel,
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                currency0: pos.poolKey.currency0.toAddress(),
                currency1: pos.poolKey.currency1.toAddress()
            })
        );
        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    /// @dev Split out of tokenURI so the legacy (coverage) codegen stays under the stack limit (Issue 5).
    function _attributes(string memory curveLabel, string memory feeLabel, string memory symbol0, string memory symbol1)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Curve","value":"',
            curveLabel,
            '"},{"trait_type":"Fee","value":"',
            feeLabel,
            '"},{"trait_type":"Token0","value":"',
            symbol0,
            '"},{"trait_type":"Token1","value":"',
            symbol1,
            '"},'
        );
    }

    function _rangeAttributes(int24 tickLower, int24 tickUpper, uint128 liquidity)
        private
        pure
        returns (string memory)
    {
        return string.concat(
            '{"trait_type":"Tick Lower","value":"',
            _int24ToString(tickLower),
            '"},{"trait_type":"Tick Upper","value":"',
            _int24ToString(tickUpper),
            '"},{"trait_type":"Liquidity","value":"',
            uint256(liquidity).toString(),
            '"}'
        );
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
        return string.concat("-", uint256(-int256(v)).toString());
    }
}
