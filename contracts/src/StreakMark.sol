// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {EIP712} from "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

/// @title StreakMark
/// @notice 连续解题 7 天及以上可以领取的不可转让标记。
///         链上无法验证「连续天数」，所以由签名者（服务端）签发 (holder, streak, deadline)，
///         合约只验证签名；同一钱包只能领取一次，且天数必须比上次多。
contract StreakMark is ERC721, EIP712 {
    bytes32 private constant TYPEHASH =
        keccak256("Streak(address holder,uint256 streak,uint256 deadline)");

    address public owner;
    address public signer;

    mapping(address => uint256) public bestDays; // 已领取的最高连续天数
    mapping(address => bool) public claimed;
    uint256 public nextId = 1;

    event Claimed(address indexed holder, uint256 tokenId, uint256 streak);
    event SignerChanged(address indexed next);

    error NotOwner();
    error BadSignature();
    error Expired();
    error BelowThreshold();
    error AlreadyClaimed();
    error NotBetter();
    error Soulbound();

    constructor(address signer_) ERC721("TapeFoundry Streak Mark", "TFSTREAK") EIP712("TapeFoundry", "1") {
        owner = msg.sender;
        signer = signer_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    function setSigner(address next) external onlyOwner {
        signer = next;
        emit SignerChanged(next);
    }

    function transferOwnership(address next) external onlyOwner {
        owner = next;
    }

    function digest(address holder, uint256 streak, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(TYPEHASH, holder, streak, deadline)));
    }

    /// @notice 领取连续标记。streak 必须是服务端确认过的连续天数。
    function claim(uint256 streak, uint256 deadline, bytes calldata sig) external returns (uint256 tokenId) {
        if (streak < 7) revert BelowThreshold();
        if (block.timestamp > deadline) revert Expired();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        if (streak <= bestDays[msg.sender]) revert NotBetter();
        if (ECDSA.recover(digest(msg.sender, streak, deadline), sig) != signer) revert BadSignature();

        claimed[msg.sender] = true;
        bestDays[msg.sender] = streak;
        tokenId = nextId++;
        _mint(msg.sender, tokenId);
        emit Claimed(msg.sender, tokenId, streak);
    }

    /// @dev 灵魂绑定：只在铸造时允许 from == 0。
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);
        if (from != address(0) && to != address(0)) revert Soulbound();
        return super._update(to, tokenId, auth);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        address holder = ownerOf(tokenId);
        uint256 streak = bestDays[holder];

        string memory json = string.concat(
            '{"name":"TapeFoundry Streak Mark #', Strings.toString(tokenId), '",',
            '"description":"A non-transferable record of a consecutive solving streak in Series 01. '
            'The number of streak was signed off chain and verified at claim time.",',
            '"image":"data:image/svg+xml;base64,', Base64.encode(bytes(_svg(tokenId, streak))), '",',
            '"attributes":[',
            '{"trait_type":"Streak","value":', Strings.toString(streak), '},',
            '{"trait_type":"Series","value":"01"},',
            '{"trait_type":"Holder","value":"', Strings.toHexString(holder), '"},',
            '{"trait_type":"Transferable","value":"no"}',
            "]}"
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    function _svg(uint256 tokenId, uint256 streak) internal pure returns (string memory) {
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="600" viewBox="0 0 600 600">',
            '<rect width="600" height="600" fill="#0E3B2E"/>',
            '<text x="48" y="96" fill="#E8B44A" font-family="monospace" font-size="14"',
            ' letter-spacing="4">TAPEFOUNDRY / SERIES 01</text>',
            '<text x="48" y="300" fill="#F6F3EC" font-family="Helvetica,Arial" font-size="96"',
            ' font-weight="600">', Strings.toString(streak), '</text>',
            '<text x="48" y="356" fill="#F6F3EC" font-family="Helvetica,Arial" font-size="40"',
            ' font-weight="600">DAY STREAK</text>',
            '<text x="48" y="410" fill="#9FBBAE" font-family="monospace" font-size="15">',
            'ONE NUMBER A DAY - SOLVED WITH A CARD</text>',
            '<text x="48" y="520" fill="#5E8073" font-family="monospace" font-size="13">',
            "#", Strings.toString(tokenId), " - NON-TRANSFERABLE</text>",
            "</svg>"
        );
    }
}
