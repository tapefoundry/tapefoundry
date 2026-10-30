// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

interface IProcessor3 {
    function ownerOf(uint256 id) external view returns (address);
    function netlist(uint256 id) external view returns (bytes memory);
}

interface IRegistry3 {
    function drawings(uint16 epoch, uint8 drawingId)
        external view returns (bytes32 hash, uint16 max, uint16 minted, bool live);
}

interface IWrapper3 {
    function wrapperOf(address cpu, uint256 circuitId) external view returns (uint256);
}

/// @title SetMark3
/// @notice Set-complete mark identified by netlist hash, so cards minted past a
///         drawing's cap still count. Supports self-claim and owner-issued mint,
///         so a holder never has to sign anything if the team issues it for them.
contract SetMark3 is ERC721 {
    address public immutable processor;
    address public immutable registry;
    address public immutable wrapper;
    uint16 public immutable epoch;
    uint8 public immutable drawingCount;
    address public owner;

    mapping(address => bool) public claimed;
    uint256 public nextId = 1;

    event MarkIssued(address indexed holder, uint256 tokenId, bool byTeam);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error AlreadyClaimed();
    error WrongCount();
    error NotHolder();
    error UnknownDrawing();
    error DuplicateDrawing();
    error IncompleteSet();
    error Soulbound();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address cpu, address reg, address wrap, uint16 epoch_, uint8 drawings_) 
        ERC721("TapeFoundry Set Mark", "TFSET")
    {
        processor = cpu;
        registry = reg;
        wrapper = wrap;
        epoch = epoch_;
        drawingCount = drawings_;
        owner = msg.sender;
    }

    function transferOwnership(address next) external onlyOwner {
        owner = next;
        emit OwnerChanged(msg.sender, next);
    }

    function _holds(address who, uint256 id) internal view returns (bool) {
        if (IProcessor3(processor).ownerOf(id) == who) return true;
        if (wrapper == address(0)) return false;
        uint256 tfd = IWrapper3(wrapper).wrapperOf(processor, id);
        if (tfd == 0) return false;
        return IERC721(wrapper).ownerOf(tfd) == who;
    }

    function _drawingOf(uint256 id) internal view returns (uint8) {
        bytes32 h = keccak256(IProcessor3(processor).netlist(id));
        for (uint8 d; d < drawingCount; d++) {
            (bytes32 registered,,,) = IRegistry3(registry).drawings(epoch, d);
            if (registered == h) return d;
        }
        revert UnknownDrawing();
    }

    function _issue(address to, uint256[] calldata ids, bool byTeam) internal returns (uint256 tokenId) {
        if (claimed[to]) revert AlreadyClaimed();
        if (ids.length != drawingCount) revert WrongCount();

        bool[] memory seen = new bool[](drawingCount);
        for (uint256 i; i < ids.length; i++) {
            if (!_holds(to, ids[i])) revert NotHolder();
            uint8 d = _drawingOf(ids[i]);
            if (seen[d]) revert DuplicateDrawing();
            seen[d] = true;
        }
        for (uint8 d; d < drawingCount; d++) {
            if (!seen[d]) revert IncompleteSet();
        }

        claimed[to] = true;
        tokenId = nextId++;
        _mint(to, tokenId);
        emit MarkIssued(to, tokenId, byTeam);
    }

    /// @notice Holder claims for themselves.
    function claim(uint256[] calldata ids) external returns (uint256) {
        return _issue(msg.sender, ids, false);
    }

    /// @notice Team issues on behalf of a holder; the wallet signs nothing.
    function mintFor(address to, uint256[] calldata ids) external onlyOwner returns (uint256) {
        return _issue(to, ids, true);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        address holder = ownerOf(tokenId);

        string memory json = string.concat(
            '{"name":"TapeFoundry Set Mark #', Strings.toString(tokenId), '",',
            '"description":"A non-transferable record that this wallet assembled the complete ',
            'Series 01 set: one circuit from each of the eleven drawings, verified on chain by netlist at issue time.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(tokenId))), '",',
            '"attributes":[',
            '{"trait_type":"Set","value":"Series 01 complete"},',
            '{"trait_type":"Drawings","value":', Strings.toString(drawingCount), '},',
            '{"trait_type":"Holder","value":"', Strings.toHexString(holder), '"},',
            '{"trait_type":"Transferable","value":"no"}',
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(uint256 tokenId) internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600" viewBox="0 0 600 600">',
            '<rect width="600" height="600" fill="#0E3B2E"/>',
            '<text x="48" y="96" fill="#E8B44A" font-family="monospace" font-size="14"',
            ' letter-spacing="4">TAPEFOUNDRY / SERIES 01</text>',
            '<text x="48" y="300" fill="#F6F3EC" font-family="Helvetica,Arial" font-size="54"',
            ' font-weight="600">SET</text>',
            '<text x="48" y="352" fill="#F6F3EC" font-family="Helvetica,Arial" font-size="54"',
            ' font-weight="600">COMPLETE</text>',
            '<text x="48" y="404" fill="#9FBBAE" font-family="monospace" font-size="15">',
            'ELEVEN DRAWINGS - ONE ARITHMETIC UNIT</text>',
            '<text x="48" y="520" fill="#5E8073" font-family="monospace" font-size="13">',
            "#", Strings.toString(tokenId), " - NON-TRANSFERABLE</text>",
            "</svg>"
        );
    }
}
