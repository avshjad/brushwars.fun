// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 *  CanvasArt — fully on-chain NFT rendering for BrushWars.
 *
 *  The finished canvas is stored as a palette-packed blob: 4096 pixels (64x64),
 *  4 bits each (a 0–15 index into a fixed 16-color palette), = 2048 bytes.
 *  tokenURI() decodes that on the fly into an SVG and wraps it, plus attributes,
 *  in a base64 data URI. Nothing lives off-chain; the art is permanent and
 *  verifiable by anyone, which is what gives the token real, checkable value.
 */
library CanvasArt {
    uint256 internal constant GRID = 64;

    // ---- Base64 (standard table) ----
    bytes internal constant B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    function base64(bytes memory data) internal pure returns (string memory) {
        if (data.length == 0) return "";
        string memory table = string(B64);
        uint256 encodedLen = 4 * ((data.length + 2) / 3);
        string memory result = new string(encodedLen + 32);
        assembly {
            let tablePtr := add(table, 1)
            let resultPtr := add(result, 32)
            for { let i := 0 } lt(i, mload(data)) { } {
                i := add(i, 3)
                let input := and(mload(add(data, i)), 0xffffff)
                let out := mload(add(tablePtr, and(shr(18, input), 0x3F)))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(12, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(shr(6, input), 0x3F))), 0xFF))
                out := shl(8, out)
                out := add(out, and(mload(add(tablePtr, and(input, 0x3F))), 0xFF))
                out := shl(224, out)
                mstore(resultPtr, out)
                resultPtr := add(resultPtr, 4)
            }
            switch mod(mload(data), 3)
            case 1 { mstore(sub(resultPtr, 2), shl(240, 0x3d3d)) }
            case 2 { mstore(sub(resultPtr, 1), shl(248, 0x3d)) }
            mstore(result, encodedLen)
        }
        return result;
    }

    // ---- uint -> decimal string ----
    function toStr(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 j = v; uint256 len;
        while (j != 0) { len++; j /= 10; }
        bytes memory b = new bytes(len);
        while (v != 0) { len--; b[len] = bytes1(uint8(48 + v % 10)); v /= 10; }
        return string(b);
    }

    // ---- address -> checksummed-ish hex string (lowercase 0x...) ----
    function toHex(address a) internal pure returns (string memory) {
        bytes memory alpha = "0123456789abcdef";
        bytes20 d = bytes20(a);
        bytes memory out = new bytes(42);
        out[0] = "0"; out[1] = "x";
        for (uint256 i = 0; i < 20; i++) {
            out[2 + i*2]     = alpha[uint8(d[i]) >> 4];
            out[3 + i*2]     = alpha[uint8(d[i]) & 0x0f];
        }
        return string(out);
    }

    // short form 0xabcd…wxyz
    function shortAddr(address a) internal pure returns (string memory) {
        string memory h = toHex(a);
        bytes memory hb = bytes(h);
        bytes memory s = new bytes(13);
        for (uint256 i = 0; i < 6; i++) s[i] = hb[i];          // 0x + 4
        s[6] = 0xE2; s[7] = 0x80; s[8] = 0xA6;                 // … (utf8 ellipsis)
        for (uint256 i = 0; i < 4; i++) s[9 + i] = hb[38 + i]; // last 4
        return string(s);
    }

    // 64-color fixed palette (must match operator + frontend exactly).
    // index 0 = background (#000000).
    function palette(uint8 i) internal pure returns (string memory) {
        if (i == 0) return "#000000";
        if (i == 1) return "#222034";
        if (i == 2) return "#45283c";
        if (i == 3) return "#663931";
        if (i == 4) return "#8f563b";
        if (i == 5) return "#df7126";
        if (i == 6) return "#d9a066";
        if (i == 7) return "#eec39a";
        if (i == 8) return "#fbf236";
        if (i == 9) return "#99e550";
        if (i == 10) return "#6abe30";
        if (i == 11) return "#37946e";
        if (i == 12) return "#4b692f";
        if (i == 13) return "#524b24";
        if (i == 14) return "#323c39";
        if (i == 15) return "#3f3f74";
        if (i == 16) return "#306082";
        if (i == 17) return "#5b6ee1";
        if (i == 18) return "#639bff";
        if (i == 19) return "#5fcde4";
        if (i == 20) return "#cbdbfc";
        if (i == 21) return "#ffffff";
        if (i == 22) return "#9badb7";
        if (i == 23) return "#847e87";
        if (i == 24) return "#696a6a";
        if (i == 25) return "#595652";
        if (i == 26) return "#76428a";
        if (i == 27) return "#ac3232";
        if (i == 28) return "#d95763";
        if (i == 29) return "#d77bba";
        if (i == 30) return "#8f974a";
        if (i == 31) return "#8a6f30";
        if (i == 32) return "#0a0a0a";
        if (i == 33) return "#3b3b3b";
        if (i == 34) return "#5c5c5c";
        if (i == 35) return "#7d7d7d";
        if (i == 36) return "#a0a0a0";
        if (i == 37) return "#c4c4c4";
        if (i == 38) return "#e0e0e0";
        if (i == 39) return "#f5f5f5";
        if (i == 40) return "#5a1e0a";
        if (i == 41) return "#7a2d10";
        if (i == 42) return "#a83b1e";
        if (i == 43) return "#cf5a2e";
        if (i == 44) return "#e88a4d";
        if (i == 45) return "#f2b079";
        if (i == 46) return "#f7d2a8";
        if (i == 47) return "#fce8cf";
        if (i == 48) return "#1a3a1a";
        if (i == 49) return "#2d5e2d";
        if (i == 50) return "#3f8a3f";
        if (i == 51) return "#5cb85c";
        if (i == 52) return "#8ad98a";
        if (i == 53) return "#1a2a4a";
        if (i == 54) return "#2d4a7a";
        if (i == 55) return "#3f6aad";
        if (i == 56) return "#5c8ad9";
        if (i == 57) return "#8ab0e8";
        if (i == 58) return "#2a1a3a";
        if (i == 59) return "#4a2d6a";
        if (i == 60) return "#6a3f9a";
        if (i == 61) return "#9a5cc8";
        if (i == 62) return "#c08ae0";
        return "#e0c0f0"; // 63
    }

    // ---- build the SVG from the packed canvas (1 byte per pixel) ----
    // Each byte is a 0–63 palette index. Background (index 0, #000000) is the
    // SVG backdrop, so we skip index-0 pixels to keep the string smaller.
    function renderSVG(bytes memory packed) internal pure returns (string memory) {
        string memory rects = "";
        for (uint256 p = 0; p < GRID * GRID; p++) {
            uint8 idx = uint8(packed[p]);
            if (idx == 0) continue; // background
            uint256 x = p % GRID; uint256 y = p / GRID;
            rects = string(abi.encodePacked(
                rects,
                '<rect x="', toStr(x), '" y="', toStr(y),
                '" width="1" height="1" fill="', palette(idx), '"/>'
            ));
        }
        return string(abi.encodePacked(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" ',
            'viewBox="0 0 64 64" shape-rendering="crispEdges">',
            '<rect width="64" height="64" fill="#000000"/>',
            rects,
            '</svg>'
        ));
    }

    struct Meta {
        uint256 round;
        address winner;     // last pixel (NFT holder)
        address topPainter; // most pixels (pot winner)
        uint256 topPixels;
        uint256 totalPixels;
        uint256 painters;   // distinct painters
        uint256 potWei;     // pot at close
        bool    byHardCap;  // true = hard cap, false = inactivity
    }

    // ---- full tokenURI: data:application/json;base64,{...} ----
    function tokenURI(bytes memory packed, Meta memory m) internal pure returns (string memory) {
        string memory svg = renderSVG(packed);
        string memory image = string(abi.encodePacked(
            "data:image/svg+xml;base64,", base64(bytes(svg))
        ));
        string memory potStr = toStr(m.potWei / 1e15); // milli-MON, avoids decimals lib
        string memory json = string(abi.encodePacked(
            '{"name":"BrushWars Canvas #', toStr(m.round),
            '","description":"The final canvas of BrushWars round ', toStr(m.round),
            '. A collaborative pixel battle on Monad. Fully on-chain art.",',
            '"image":"', image, '","attributes":[',
                '{"trait_type":"Round","value":', toStr(m.round), '},',
                '{"trait_type":"NFT Winner (last pixel)","value":"', shortAddr(m.winner), '"},',
                '{"trait_type":"Pot Winner (most pixels)","value":"', shortAddr(m.topPainter), '"},',
                '{"trait_type":"Top Painter Pixels","value":', toStr(m.topPixels), '},',
                '{"trait_type":"Total Pixels","value":', toStr(m.totalPixels), '},',
                '{"trait_type":"Distinct Painters","value":', toStr(m.painters), '},',
                '{"trait_type":"Pot (mMON)","value":', potStr, '},',
                '{"trait_type":"Closed By","value":"', m.byHardCap ? "Hard Cap" : "Inactivity", '"}',
            ']}'
        ));
        return string(abi.encodePacked(
            "data:application/json;base64,", base64(bytes(json))
        ));
    }
}
