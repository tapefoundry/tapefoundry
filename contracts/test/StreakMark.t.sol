// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {StreakMark} from "../src/StreakMark.sol";

contract StreakMarkTest is Test {
    StreakMark mark;
    uint256 signerKey = 0xA11CE;
    address signer;
    address user = address(0xBEEF);

    function setUp() public {
        signer = vm.addr(signerKey);
        mark = new StreakMark(signer);
    }

    /// @dev 先算签名再 prank —— 否则 digest 的 staticcall 会把 prank 吃掉。
    function _sig(address who, uint256 streak, uint256 deadline) internal view returns (bytes memory) {
        bytes32 d = mark.digest(who, streak, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, d);
        return abi.encodePacked(r, s, v);
    }

    function testClaim() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sig(user, 7, deadline);
        vm.prank(user);
        uint256 id = mark.claim(7, deadline, sig);
        assertEq(id, 1);
        assertEq(mark.ownerOf(1), user);
        assertEq(mark.bestDays(user), 7);
    }

    function testRejectBelowThreshold() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sig(user, 6, deadline);
        vm.prank(user);
        vm.expectRevert(StreakMark.BelowThreshold.selector);
        mark.claim(6, deadline, sig);
    }

    function testRejectWrongSigner() public {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, mark.digest(user, 7, deadline));
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(user);
        vm.expectRevert(StreakMark.BadSignature.selector);
        mark.claim(7, deadline, sig);
    }

    function testRejectReplayByOther() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sig(user, 7, deadline);
        vm.prank(address(0xCAFE));
        vm.expectRevert(StreakMark.BadSignature.selector);
        mark.claim(7, deadline, sig);
    }

    function testRejectExpired() public {
        uint256 deadline = block.timestamp - 1;
        bytes memory sig = _sig(user, 7, deadline);
        vm.prank(user);
        vm.expectRevert(StreakMark.Expired.selector);
        mark.claim(7, deadline, sig);
    }

    function testNoDoubleClaim() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory first = _sig(user, 7, deadline);
        bytes memory second = _sig(user, 9, deadline);
        vm.prank(user);
        mark.claim(7, deadline, first);
        vm.prank(user);
        vm.expectRevert(StreakMark.AlreadyClaimed.selector);
        mark.claim(9, deadline, second);
    }

    function testSoulbound() public {
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _sig(user, 7, deadline);
        vm.prank(user);
        mark.claim(7, deadline, sig);
        vm.prank(user);
        vm.expectRevert(StreakMark.Soulbound.selector);
        mark.transferFrom(user, address(0x1234), 1);
    }
}
