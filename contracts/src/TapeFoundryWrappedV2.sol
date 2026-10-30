// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ERC2981} from "openzeppelin-contracts/contracts/token/common/ERC2981.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

interface ICircuits {
    function ownerOf(uint256 id) external view returns (address);
    function netlist(uint256 id) external view returns (bytes memory);
    function circuitInfo(uint256 id)
        external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates);
}

interface IEditions {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
    function drawings(uint16 epoch, uint8 drawingId)
        external view returns (bytes32 hash, uint16 max, uint16 minted, bool live);
}

/// @title TapeFoundry Wrapped v2
/// @notice 原卡锁进来，换一张带图、带版税、带来源校验的卡出去。
///
///         v1 → v2 的三处改动：
///         1. 5% 版税（ERC-2981），二级市场成交自动分给我们
///         2. 包装前校验网表 hash 与编号册里登记的图纸一致 —— 仿制的卡进不来
///         3. 元数据里带上 epoch / drawing，多个系列可以共存
contract TapeFoundryWrappedV2 is ERC721, ERC2981, Ownable {
    struct Original {
        address cpu;
        uint32 circuitId;
        uint32 gates;
        uint16 edition;
        uint16 epoch;
        uint8 drawing;
    }

    mapping(address => bool) public processor;
    mapping(uint256 => Original) public original;
    mapping(address => mapping(uint256 => uint256)) public wrapperOf;

    address public registry;
    uint16 public maxEdition = 700;
    uint256 public nextId;
    mapping(uint8 => string) public label;
    mapping(uint8 => uint16) public drawingMax;   // 每张图纸的发行上限

    error NotProcessor();
    error NotHolder();
    error AlreadyWrapped();
    error NotWrapped();
    error NoCircuit();
    error UnknownDrawing();
    error HashMismatch();

    event Wrapped(uint256 indexed id, address indexed cpu, uint256 indexed circuitId,
                  uint16 epoch, uint8 drawing, uint16 edition, address holder);
    event Unwrapped(uint256 indexed id, address indexed holder);

    constructor(address initialOwner)
        ERC721("TapeFoundry Series 01", "TFD")
        Ownable(initialOwner)
    {
        _setDefaultRoyalty(initialOwner, 500);   // 5%
    }

    // ───────── 管理 ─────────
    function setProcessor(address cpu, bool ok) external onlyOwner {
        processor[cpu] = ok;
    }

    function setRegistry(address r) external onlyOwner {
        registry = r;
    }

    function setMaxEdition(uint16 m) external onlyOwner {
        maxEdition = m;
    }

    function setLabel(uint8 drawingId, string calldata name) external onlyOwner {
        label[drawingId] = name;
    }

    function setDrawingMax(uint8 drawingId, uint16 m) external onlyOwner {
        drawingMax[drawingId] = m;
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        _setDefaultRoyalty(receiver, bps);
    }

    // ───────── 包装 ─────────
    /// @notice 先 approve 原卡给本合约，再调用。
    /// @param epoch     图纸所在期号
    /// @param drawingId 图纸编号（用于核对网表 hash）
    function wrap(uint16 epoch, uint8 drawingId, address cpu, uint256 circuitId)
        external
        returns (uint256 id)
    {
        if (!processor[cpu]) revert NotProcessor();
        if (wrapperOf[cpu][circuitId] != 0) revert AlreadyWrapped();
        if (IERC721(cpu).ownerOf(circuitId) != msg.sender) revert NotHolder();
        if (circuitId > type(uint32).max) revert NoCircuit();

        (,,, uint32 gates) = ICircuits(cpu).circuitInfo(circuitId);
        if (gates == 0) revert NoCircuit();

        // 只认登记过的图纸：网表 hash 必须和编号册里的一致
        if (registry == address(0)) revert UnknownDrawing();
        (bytes32 expected,,,) = IEditions(registry).drawings(epoch, drawingId);
        if (expected == bytes32(0)) revert UnknownDrawing();
        if (keccak256(ICircuits(cpu).netlist(circuitId)) != expected) revert HashMismatch();

        (uint16 edEpoch, uint8 edDrawing, uint16 number) = _edition(cpu, circuitId);
        edEpoch;

        IERC721(cpu).transferFrom(msg.sender, address(this), circuitId);

        id = ++nextId;
        original[id] = Original(cpu, uint32(circuitId), gates, number, epoch, drawingId);
        wrapperOf[cpu][circuitId] = id;
        _safeMint(msg.sender, id);

        emit Wrapped(id, cpu, circuitId, epoch, drawingId, number, msg.sender);
        edDrawing;
    }

    function unwrap(uint256 id) external {
        if (ownerOf(id) != msg.sender) revert NotHolder();
        Original memory o = original[id];
        if (o.cpu == address(0)) revert NotWrapped();

        delete original[id];
        delete wrapperOf[o.cpu][o.circuitId];
        _burn(id);

        IERC721(o.cpu).transferFrom(address(this), msg.sender, o.circuitId);
        emit Unwrapped(id, msg.sender);
    }

    /// @notice 包装时还没领编号的，领完刷一下。
    function refresh(uint256 id) external {
        Original storage o = original[id];
        if (o.cpu == address(0)) revert NotWrapped();
        (uint16 e, uint8 d, uint16 n) = _edition(o.cpu, o.circuitId);
        e;
        o.drawing = d;
        o.edition = n;
    }

    function _edition(address cpu, uint256 circuitId)
        internal view returns (uint16, uint8, uint16)
    {
        if (registry == address(0)) return (0, 0, 0);
        try IEditions(registry).editionOf(cpu, circuitId)
            returns (uint16 e, uint8 d, uint16 n)
        {
            return (e, d, n);
        } catch {
            return (0, 0, 0);
        }
    }

    // ───────── 元数据 ─────────
    function tokenURI(uint256 id) public view override returns (string memory) {
        Original memory o = original[id];
        require(o.cpu != address(0), "no such token");

        string memory code = bytes(label[o.drawing]).length > 0
            ? label[o.drawing]
            : string.concat("DRAWING ", Strings.toString(o.drawing));

        uint16 cap = drawingMax[o.drawing] == 0 ? maxEdition : drawingMax[o.drawing];
        string memory ed = o.edition == 0
            ? "UNSTAMPED"
            : string.concat(Strings.toString(o.edition), " / ", Strings.toString(cap));

        string memory json = string.concat(
            '{"name":"TapeFoundry ', code, " #", Strings.toString(id), '",',
            '"description":"A circuit taped out on TapeOut, wrapped so its drawing, gate count '
            'and edition travel with the token. The original circuit is held by this contract. '
            'The netlist hash is checked against the on-chain registry at wrap time.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(code, o, ed))), '",',
            '"attributes":[',
            '{"trait_type":"Drawing","value":"', code, '"},',
            '{"trait_type":"Gates","value":', Strings.toString(o.gates), '},',
            '{"trait_type":"Edition","value":"', ed, '"},',
            '{"trait_type":"Series","value":', Strings.toString(o.epoch), '},',
            '{"trait_type":"Processor","value":"', Strings.toHexString(o.cpu), '"},',
            '{"trait_type":"Source token","value":"', Strings.toString(o.circuitId), '"}',
            "]}"
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(string memory code, Original memory o, string memory ed)
        internal pure returns (string memory)
    {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="800" viewBox="0 0 600 800">',
            '<rect width="600" height="800" fill="#fbfaf7"/>',
            '<rect x="28" y="28" width="544" height="744" fill="none" stroke="#14532d" stroke-width="2"/>',
            '<text x="56" y="92" font-family="monospace" font-size="13" letter-spacing="3" fill="#7c7c75">TAPEFOUNDRY</text>',
            '<line x1="56" y1="112" x2="544" y2="112" stroke="#e7e5df" stroke-width="1"/>',
            '<text x="52" y="232" font-family="Helvetica,Arial,sans-serif" font-size="60" font-weight="700" fill="#1d1d1b">',
            code, "</text>",
            '<text x="56" y="284" font-family="Helvetica,Arial,sans-serif" font-size="22" fill="#14532d">',
            Strings.toString(o.gates), o.gates == 1 ? " gate" : " gates", "</text>",
            '<text x="56" y="392" font-family="monospace" font-size="12" letter-spacing="2" fill="#7c7c75">EDITION</text>',
            '<text x="52" y="470" font-family="Helvetica,Arial,sans-serif" font-size="56" font-weight="700" fill="#14532d">',
            ed, "</text>",
            '<line x1="56" y1="530" x2="544" y2="530" stroke="#e7e5df" stroke-width="1"/>',
            '<text x="56" y="574" font-family="monospace" font-size="11" fill="#7c7c75">processor</text>',
            '<text x="56" y="596" font-family="monospace" font-size="11" fill="#4a4a45">',
            Strings.toHexString(o.cpu), "</text>",
            '<text x="56" y="628" font-family="monospace" font-size="11" fill="#7c7c75">circuit</text>',
            '<text x="56" y="650" font-family="monospace" font-size="11" fill="#4a4a45">#',
            Strings.toString(o.circuitId), "</text>",
            '<text x="56" y="728" font-family="monospace" font-size="10" fill="#a8a8a0">',
            "rarity is the number of gates that actually burned</text>",
            "</svg>"
        );
    }

    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, ERC2981)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
