// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

interface ICircuits {
    function ownerOf(uint256 id) external view returns (address);
    function circuitInfo(uint256 id)
        external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates);
}

interface IEditions {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
}

/// @title TapeFoundry Wrapped
/// @notice 原卡锁进来，换一张带图的卡出去。
///
///         TapeOut 的电路 NFT 没有 tokenURI —— 在任何市场上都是一张白卡。
///         这里把原卡托管，铸一张同源的 ERC-721：图、门数、编号、来源全部写死在链上，
///         不需要我们的服务器，Element 这类市场直接能读。
///
///         元数据全部 on-chain（SVG + base64 JSON），所以我们关站了这些卡也不会变成空白。
contract TapeFoundryWrapped is ERC721, Ownable {
    struct Original {
        address cpu;
        uint32 circuitId;
        uint32 gates;
        uint16 edition;
        uint8 drawing;
    }

    mapping(address => bool) public processor;
    mapping(uint256 => Original) public original;              // wrapperId => 原卡
    mapping(address => mapping(uint256 => uint256)) public wrapperOf;  // cpu => circuitId => wrapperId

    address public registry;
    uint16 public maxEdition = 100;
    uint256 public nextId;
    mapping(uint8 => string) public label;                     // drawingId => "ADD4"

    error NotProcessor();
    error NotHolder();
    error AlreadyWrapped();
    error NotWrapped();
    error NoCircuit();

    event Wrapped(uint256 indexed id, address indexed cpu, uint256 indexed circuitId,
                  uint16 edition, address holder);
    event Unwrapped(uint256 indexed id, address indexed holder);

    constructor(address initialOwner)
        ERC721("TapeFoundry", "TFD")
        Ownable(initialOwner)
    {}

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

    // ───────── 包装 ─────────
    /// @notice 先把原卡 approve 给本合约，再调用这里。
    function wrap(address cpu, uint256 circuitId) external returns (uint256 id) {
        if (!processor[cpu]) revert NotProcessor();
        // 先判"已经包过了" —— 否则持有人的检查会先报 NotHolder（包装后原卡归合约所有），
        // 用户看到的是个误导性的错误
        if (wrapperOf[cpu][circuitId] != 0) revert AlreadyWrapped();
        if (IERC721(cpu).ownerOf(circuitId) != msg.sender) revert NotHolder();

        if (circuitId > type(uint32).max) revert NoCircuit();
        (,,, uint32 gates) = ICircuits(cpu).circuitInfo(circuitId);
        if (gates == 0) revert NoCircuit();

        (uint16 epoch, uint8 drawing, uint16 number) = _edition(cpu, circuitId);
        epoch; // 期号暂时不展示，留着给以后

        IERC721(cpu).transferFrom(msg.sender, address(this), circuitId);

        id = ++nextId;
        original[id] = Original(cpu, uint32(circuitId), gates, number, drawing);
        wrapperOf[cpu][circuitId] = id;
        _safeMint(msg.sender, id);

        emit Wrapped(id, cpu, circuitId, number, msg.sender);
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

    /// @notice 包装时还没领编号的，领完可以刷一下，不用解包重来。
    function refresh(uint256 id) external {
        Original storage o = original[id];
        if (o.cpu == address(0)) revert NotWrapped();
        (uint16 epoch, uint8 drawing, uint16 number) = _edition(o.cpu, o.circuitId);
        epoch;
        o.drawing = drawing;
        o.edition = number;
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

        string memory ed = o.edition == 0
            ? "UNSTAMPED"
            : string.concat(Strings.toString(o.edition), " / ", Strings.toString(maxEdition));

        string memory json = string.concat(
            '{"name":"TapeFoundry ', code, " #", Strings.toString(id), '",',
            '"description":"A circuit taped out on TapeOut, wrapped so its drawing, gate count '
            'and edition travel with the token. The original circuit is held by this contract.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(code, o, ed))), '",',
            '"attributes":[',
            '{"trait_type":"Drawing","value":"', code, '"},',
            '{"trait_type":"Gates","value":', Strings.toString(o.gates), '},',
            '{"trait_type":"Edition","value":"', ed, '"},',
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
            '<text x="52" y="232" font-family="Helvetica,Arial,sans-serif" font-size="86" font-weight="700" fill="#1d1d1b">',
            code, "</text>",
            '<text x="56" y="284" font-family="Helvetica,Arial,sans-serif" font-size="22" fill="#14532d">',
            Strings.toString(o.gates), o.gates == 1 ? " gate" : " gates", "</text>",
            '<text x="56" y="392" font-family="monospace" font-size="12" letter-spacing="2" fill="#7c7c75">EDITION</text>',
            '<text x="52" y="470" font-family="Helvetica,Arial,sans-serif" font-size="62" font-weight="700" fill="#14532d">',
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
}
