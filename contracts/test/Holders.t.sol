// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SeriesVote} from "../src/SeriesVote.sol";
import {SetMark} from "../src/SetMark.sol";

contract MockCircuits {
    mapping(uint256 => address) public owner;

    function setOwner(uint256 id, address who) external {
        owner[id] = who;
    }

    function ownerOf(uint256 id) external view returns (address) {
        address o = owner[id];
        require(o != address(0), "nonexistent");
        return o;
    }
}

contract MockEditions {
    mapping(uint256 => uint8) public drawing;
    mapping(uint256 => uint16) public epochOf;

    function set(uint256 id, uint8 d, uint16 e) external {
        drawing[id] = d;
        epochOf[id] = e;
    }

    function editionOf(address, uint256 id)
        external
        view
        returns (uint16, uint8, uint16)
    {
        return (epochOf[id], drawing[id], 1);
    }
}

contract SeriesVoteTest is Test {
    SeriesVote vote;
    MockCircuits cpu;
    MockEditions reg;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        cpu = new MockCircuits();
        reg = new MockEditions();
        string[] memory opts = new string[](3);
        opts[0] = "REG8";
        opts[1] = "COUNTER8";
        opts[2] = "REGFILE";
        vote = new SeriesVote(address(cpu), address(reg), 1, opts);

        cpu.setOwner(1, alice);
        cpu.setOwner(2, alice);
        cpu.setOwner(3, bob);
        reg.set(1, 5, 1);
        reg.set(2, 9, 1);
        reg.set(3, 5, 1);
    }

    function testVoteByCardCount() public {
        vote.setOpen(true);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        vm.prank(alice);
        vote.vote(1, ids);

        assertEq(vote.tally(1), 2);
        assertEq(vote.totalVotes(), 2);
        assertTrue(vote.voted(1));
    }

    function testCannotVoteTwiceWithSameCard() public {
        vote.setOpen(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        vote.vote(0, ids);

        vm.prank(alice);
        vm.expectRevert(SeriesVote.AlreadyVoted.selector);
        vote.vote(0, ids);
    }

    function testCannotVoteSomeoneElsesCard() public {
        vote.setOpen(true);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 3;
        vm.prank(alice);
        vm.expectRevert(SeriesVote.NotOwner.selector);
        vote.vote(0, ids);
    }

    function testCannotVoteWhenClosed() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        vm.expectRevert(SeriesVote.Closed.selector);
        vote.vote(0, ids);
    }

    function testOnlyOwnerOpens() public {
        vm.prank(alice);
        vm.expectRevert(SeriesVote.NotOwnerOfContract.selector);
        vote.setOpen(true);
    }

    function testDifferentCardsCanSplitAcrossChoices() public {
        vote.setOpen(true);
        uint256[] memory a = new uint256[](1);
        a[0] = 1;
        uint256[] memory b = new uint256[](1);
        b[0] = 2;
        vm.startPrank(alice);
        vote.vote(0, a);
        vote.vote(2, b);
        vm.stopPrank();
        assertEq(vote.tally(0), 1);
        assertEq(vote.tally(2), 1);
        assertEq(vote.totalVotes(), 2);
    }
}

contract MockWrapper {
    mapping(uint256 => uint256) public tfdOf;
    mapping(uint256 => address) public owners;

    function set(uint256 circuitId, uint256 tfdId, address who) external {
        tfdOf[circuitId] = tfdId;
        owners[tfdId] = who;
    }

    function wrapperOf(address, uint256 circuitId) external view returns (uint256) {
        return tfdOf[circuitId];
    }

    function ownerOf(uint256 tfdId) external view returns (address) {
        return owners[tfdId];
    }
}

contract SetMarkTest is Test {
    SetMark mark;
    MockCircuits cpu;
    MockEditions reg;
    address alice = address(0xA11CE);

    function setUp() public {
        cpu = new MockCircuits();
        reg = new MockEditions();
        mark = new SetMark(address(cpu), address(reg), address(0), 1, 3);
    }

    function _give(address who, uint256 id, uint8 drawing) internal {
        cpu.setOwner(id, who);
        reg.set(id, drawing, 1);
    }

    function testClaimCompleteSet() public {
        _give(alice, 10, 0);
        _give(alice, 11, 1);
        _give(alice, 12, 2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;

        vm.prank(alice);
        uint256 id = mark.claim(ids);
        assertEq(id, 1);
        assertEq(mark.ownerOf(1), alice);
        assertTrue(mark.claimed(alice));
    }

    function testRejectsDuplicateDrawing() public {
        _give(alice, 10, 0);
        _give(alice, 11, 0);
        _give(alice, 12, 2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;

        vm.prank(alice);
        vm.expectRevert(SetMark.DuplicateDrawing.selector);
        mark.claim(ids);
    }

    function testRejectsIncompleteSet() public {
        _give(alice, 10, 0);
        _give(alice, 11, 1);
        _give(alice, 12, 1);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;

        vm.prank(alice);
        vm.expectRevert(SetMark.DuplicateDrawing.selector);
        mark.claim(ids);
    }

    function testRejectsTwice() public {
        _give(alice, 10, 0);
        _give(alice, 11, 1);
        _give(alice, 12, 2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;
        vm.startPrank(alice);
        mark.claim(ids);
        vm.expectRevert(SetMark.AlreadyClaimed.selector);
        mark.claim(ids);
        vm.stopPrank();
    }

    function testSoulbound() public {
        _give(alice, 10, 0);
        _give(alice, 11, 1);
        _give(alice, 12, 2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;
        vm.prank(alice);
        mark.claim(ids);

        vm.prank(alice);
        vm.expectRevert(SetMark.Soulbound.selector);
        mark.transferFrom(alice, address(0xB0B), 1);
    }

    function testWrappedCardsCount() public {
        MockWrapper w = new MockWrapper();
        SetMark m2 = new SetMark(address(cpu), address(reg), address(w), 1, 3);
        // 原卡锁在包装合约里，TFD 在 alice 手上
        _give(address(w), 20, 0);
        _give(address(w), 21, 1);
        _give(address(w), 22, 2);
        w.set(20, 100, alice);
        w.set(21, 101, alice);
        w.set(22, 102, alice);

        uint256[] memory ids = new uint256[](3);
        ids[0] = 20; ids[1] = 21; ids[2] = 22;
        vm.prank(alice);
        m2.claim(ids);
        assertEq(m2.ownerOf(1), alice);
    }

    function testTokenUriHasSetComplete() public {
        _give(alice, 10, 0);
        _give(alice, 11, 1);
        _give(alice, 12, 2);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 10;
        ids[1] = 11;
        ids[2] = 12;
        vm.prank(alice);
        mark.claim(ids);
        string memory uri = mark.tokenURI(1);
        assertGt(bytes(uri).length, 100);
    }
}
