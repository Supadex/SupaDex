// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LibString} from "solady/utils/LibString.sol";

/**
 * @title NFTSVGLib
 * @notice Generates SupaDex "Obsidian Lattice" on-chain SVG for position NFTs.
 * @dev Distinct from Uniswap's sparkle card — monochrome obsidian plane, titanium
 *      orbital arcs for range, deterministic constellation seeded by tokenId, and
 *      curve-glyph identity (CLAMM / BinAMM / StableAMM).
 */
library NFTSVGLib {
    using LibString for uint256;

    struct SVGParams {
        uint256 tokenId;
        string symbol0;
        string symbol1;
        string curveLabel;
        uint8 curveType; // 0 CLAMM, 1 BIN, 2 STABLE
        string feeLabel;
        int24 tickLower;
        int24 tickUpper;
        address currency0;
        address currency1;
    }

    function generateSVG(SVGParams memory p) internal pure returns (string memory) {
        string memory accent = _accentForCurve(p.curveType);
        (uint256 startDeg, uint256 spanDeg) = _rangeArc(p.tickLower, p.tickUpper, p.curveType);
        string memory stars = _constellation(p.tokenId, p.currency0, p.currency1);
        string memory glyph = _curveGlyph(p.curveType, accent);

        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512" fill="none">',
            '<defs>',
            '<radialGradient id="gBg" cx="38%" cy="28%" r="78%">',
            '<stop offset="0%" stop-color="#16181D"/>',
            '<stop offset="55%" stop-color="#0C0D10"/>',
            '<stop offset="100%" stop-color="#08090B"/>',
            '</radialGradient>',
            '<linearGradient id="gRing" x1="0" y1="0" x2="1" y2="1">',
            '<stop offset="0%" stop-color="#E8EAED" stop-opacity="0.92"/>',
            '<stop offset="100%" stop-color="#94A3B8" stop-opacity="0.35"/>',
            '</linearGradient>',
            '<filter id="glow"><feGaussianBlur stdDeviation="2.2" result="b"/>',
            '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
            '</defs>',
            '<rect width="512" height="512" fill="url(#gBg)"/>',
            // hairline frame
            '<rect x="18" y="18" width="476" height="476" rx="28" stroke="rgba(255,255,255,0.08)" stroke-width="1"/>',
            '<rect x="28" y="28" width="456" height="456" rx="22" stroke="rgba(255,255,255,0.04)" stroke-width="1"/>',
            stars,
            // dormant full orbit
            '<circle cx="256" cy="236" r="128" stroke="rgba(148,163,184,0.14)" stroke-width="1.25"/>',
            '<circle cx="256" cy="236" r="96" stroke="rgba(148,163,184,0.08)" stroke-width="1"/>',
            // active range arc (stroke-dasharray on circumference ~804 for r=128)
            _rangePath(startDeg, spanDeg, accent),
            // core node
            '<circle cx="256" cy="236" r="6" fill="',
            accent,
            '" filter="url(#glow)"/>',
            '<circle cx="256" cy="236" r="2.5" fill="#F8FAFC"/>',
            glyph,
            // brand + meta
            '<text x="44" y="64" fill="#F8FAFC" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="15" font-weight="700" letter-spacing="2">SUPADEX</text>',
            '<text x="44" y="86" fill="#64748B" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="11" letter-spacing="1.5">POSITION LATTICE</text>',
            '<text x="468" y="64" text-anchor="end" fill="#94A3B8" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="12">#',
            p.tokenId.toString(),
            '</text>',
            // pair
            '<text x="256" y="400" text-anchor="middle" fill="#F8FAFC" font-family="ui-sans-serif,system-ui,-apple-system,sans-serif" font-size="28" font-weight="700">',
            _escape(p.symbol0),
            ' / ',
            _escape(p.symbol1),
            '</text>',
            // badges
            '<rect x="118" y="420" width="110" height="28" rx="8" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.08)"/>',
            '<text x="173" y="439" text-anchor="middle" fill="',
            accent,
            '" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="11" font-weight="600">',
            p.curveLabel,
            '</text>',
            '<rect x="240" y="420" width="72" height="28" rx="8" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.08)"/>',
            '<text x="276" y="439" text-anchor="middle" fill="#CBD5E1" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="11" font-weight="600">',
            p.feeLabel,
            '</text>',
            '<rect x="324" y="420" width="70" height="28" rx="8" fill="rgba(255,255,255,0.04)" stroke="rgba(255,255,255,0.08)"/>',
            '<text x="359" y="439" text-anchor="middle" fill="#94A3B8" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="10">LP NFT</text>',
            // footer ticks
            '<text x="256" y="472" text-anchor="middle" fill="#475569" font-family="ui-monospace,SFMono-Regular,Menlo,monospace" font-size="10">',
            _tickLabel(p.tickLower, p.tickUpper, p.curveType),
            '</text>',
            '</svg>'
        );
    }

    function _accentForCurve(uint8 curveType) private pure returns (string memory) {
        if (curveType == 1) return "#FBBF24"; // BinAMM amber
        if (curveType == 2) return "#94A3B8"; // Stable titanium
        return "#34D399"; // CLAMM sage
    }

    function _curveGlyph(uint8 curveType, string memory accent) private pure returns (string memory) {
        if (curveType == 1) {
            // bin grid
            return string.concat(
                '<g transform="translate(400 52)" stroke="',
                accent,
                '" stroke-width="1.4" fill="none" opacity="0.9">',
                '<rect x="0" y="0" width="14" height="14" rx="2"/>',
                '<rect x="18" y="0" width="14" height="14" rx="2"/>',
                '<rect x="0" y="18" width="14" height="14" rx="2"/>',
                '<rect x="18" y="18" width="14" height="14" rx="2" fill="',
                accent,
                '" fill-opacity="0.35"/>',
                '</g>'
            );
        }
        if (curveType == 2) {
            // stableswap lemniscate-ish ellipses
            return string.concat(
                '<g transform="translate(402 58)" fill="none" stroke="',
                accent,
                '" stroke-width="1.5" opacity="0.95">',
                '<ellipse cx="14" cy="14" rx="16" ry="9"/>',
                '<ellipse cx="14" cy="14" rx="9" ry="16"/>',
                '</g>'
            );
        }
        // CLAMM chevron / concentrated wedge
        return string.concat(
            '<g transform="translate(404 54)" fill="none" stroke="',
            accent,
            '" stroke-width="1.6" opacity="0.95">',
            '<path d="M4 28 L18 4 L32 28"/>',
            '<path d="M10 28 L18 14 L26 28" opacity="0.55"/>',
            '</g>'
        );
    }

    function _rangeArc(int24 tickLower, int24 tickUpper, uint8 curveType)
        private
        pure
        returns (uint256 startDeg, uint256 spanDeg)
    {
        if (curveType == 1) {
            // single-bin: short bright arc
            return (210, 40);
        }
        if (curveType == 2) {
            return (160, 80);
        }
        // Map tick span into [24, 300] degrees
        int256 span = int256(tickUpper) - int256(tickLower);
        if (span < 0) span = -span;
        // full-range-ish
        if (span > 1_000_000) return (40, 300);
        uint256 mapped = uint256(span) / 400; // rough scale
        if (mapped < 24) mapped = 24;
        if (mapped > 300) mapped = 300;
        // seed start from lower tick
        int256 start = int256(tickLower);
        if (start < 0) start = -start;
        startDeg = 40 + (uint256(start) % 200);
        spanDeg = mapped;
    }

    function _rangePath(uint256 startDeg, uint256 spanDeg, string memory accent)
        private
        pure
        returns (string memory)
    {
        // Approximate arc with stroke-dasharray on circle (C ≈ 804)
        uint256 circ = 804;
        uint256 dash = (spanDeg * circ) / 360;
        if (dash < 20) dash = 20;
        uint256 gap = circ - dash;
        uint256 rot = startDeg;
        return string.concat(
            '<circle cx="256" cy="236" r="128" stroke="url(#gRing)" stroke-width="3.5" ',
            'stroke-linecap="round" fill="none" filter="url(#glow)" ',
            'stroke-dasharray="',
            dash.toString(),
            ' ',
            gap.toString(),
            '" transform="rotate(',
            rot.toString(),
            ' 256 236)"/>',
            '<circle cx="256" cy="236" r="128" stroke="',
            accent,
            '" stroke-opacity="0.55" stroke-width="1.25" ',
            'stroke-linecap="round" fill="none" ',
            'stroke-dasharray="',
            dash.toString(),
            ' ',
            gap.toString(),
            '" transform="rotate(',
            rot.toString(),
            ' 256 236)"/>'
        );
    }

    function _constellation(uint256 tokenId, address c0, address c1)
        private
        pure
        returns (string memory)
    {
        bytes32 seed = keccak256(abi.encodePacked(tokenId, c0, c1));
        string memory out;
        // 7 deterministic stars
        for (uint256 i = 0; i < 7; i++) {
            uint8 b0 = uint8(seed[i]);
            uint8 b1 = uint8(seed[i + 7]);
            uint256 x = 56 + (uint256(b0) % 400);
            uint256 y = 56 + (uint256(b1) % 360);
            uint256 r = 1 + (uint256(b0) % 2);
            uint256 op = 18 + (uint256(b1) % 40); // 18-57 → opacity 0.18-0.57
            out = string.concat(
                out,
                '<circle cx="',
                x.toString(),
                '" cy="',
                y.toString(),
                '" r="',
                r.toString(),
                '" fill="#E2E8F0" fill-opacity="0.',
                op.toString(),
                '"/>'
            );
        }
        return out;
    }

    function _tickLabel(int24 tickLower, int24 tickUpper, uint8 curveType)
        private
        pure
        returns (string memory)
    {
        if (curveType == 1) {
            return string.concat("BIN ", _int24ToString(tickLower));
        }
        return string.concat("TICKS ", _int24ToString(tickLower), " -> ", _int24ToString(tickUpper));
    }

    function _int24ToString(int24 v) private pure returns (string memory) {
        if (v >= 0) return uint256(uint24(v)).toString();
        uint256 abs = uint256(uint24(-v));
        return string.concat("-", abs.toString());
    }

    function _escape(string memory s) private pure returns (string memory) {
        bytes memory b = bytes(s);
        // strip chars that break SVG/XML text nodes
        bytes memory out = new bytes(b.length);
        uint256 n;
        for (uint256 i; i < b.length; i++) {
            bytes1 c = b[i];
            if (c == "<" || c == ">" || c == "&" || c == '"') continue;
            out[n++] = c;
        }
        bytes memory trimmed = new bytes(n);
        for (uint256 j; j < n; j++) {
            trimmed[j] = out[j];
        }
        return string(trimmed);
    }
}
