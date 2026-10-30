// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";

interface IOwnerOf2 {
    function ownerOf(uint256 id) external view returns (address);
}

interface IWrapper {
    function wrapperOf(address cpu, uint256 circuitId) external view returns (uint256);
}

interface IEditionOf2 {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
}

/// @title SetMark
/// @notice 集齐一套（每个图纸各至少一张）后可以领取的不可转让标记。
///         领取时在链上校验：每张卡的持有人、期号、图纸编号，缺一不可。
contract SetMark is ERC721 {
    address public immutable processor;
    address public immutable registry;
    address public immutable wrapper;
    uint16 public immutable epoch;
    uint8 public immutable drawingCount;

    mapping(address => bool) public claimed;
    uint256 public nextId = 1;

    event MarkClaimed(address indexed holder, uint256 tokenId);

    error AlreadyClaimed();
    error WrongCount();
    error NotOwner();
    error WrongEpoch();
    error DuplicateDrawing();
    error IncompleteSet();
    error Soulbound();

    constructor(address cpu, address reg, address wrap, uint16 epoch_, uint8 drawings_)
        ERC721("TapeFoundry Set Mark", "TFSET")
    {
        processor = cpu;
        registry = reg;
        wrapper = wrap;
        epoch = epoch_;
        drawingCount = drawings_;
    }

    /// @dev 原卡在钱包里，或者原卡被包装、TFD 在钱包里，都算持有。
    function _holds(address who, uint256 id) internal view returns (bool) {
        if (IOwnerOf2(processor).ownerOf(id) == who) return true;
        if (wrapper == address(0)) return false;
        uint256 tfd = IWrapper(wrapper).wrapperOf(processor, id);
        if (tfd == 0) return false;
        return IERC721(wrapper).ownerOf(tfd) == who;
    }

    /// @notice ids 必须每个图纸各一张，顺序不限。
    function claim(uint256[] calldata ids) external returns (uint256 tokenId) {
        if (claimed[msg.sender]) revert AlreadyClaimed();
        if (ids.length != drawingCount) revert WrongCount();

        bool[] memory seen = new bool[](drawingCount);
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (!_holds(msg.sender, id)) revert NotOwner();
            (uint16 e, uint8 d,) = IEditionOf2(registry).editionOf(processor, id);
            if (e != epoch) revert WrongEpoch();
            if (d >= drawingCount || seen[d]) revert DuplicateDrawing();
            seen[d] = true;
        }
        for (uint256 d; d < drawingCount; d++) {
            if (!seen[d]) revert IncompleteSet();
        }

        claimed[msg.sender] = true;
        tokenId = nextId++;
        _mint(msg.sender, tokenId);
        emit MarkClaimed(msg.sender, tokenId);
    }

    /// @notice 灵魂绑定：只在铸造时允许 from == 0。
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
            'Series 01 set: one circuit from each of the eleven drawings, verified on chain at claim time.",',
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
