// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SeriesVoteV2} from "../src/SeriesVoteV2.sol";

contract MockCircuitV2 {
    mapping(uint256 => address) public ownerOf;

    function setOwner(uint256 id, address who) external {
        ownerOf[id] = who;
    }
}

contract MockEditionsV2 {
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

contract MockStakingV2 {
    struct Stake {
        address owner;
        uint32 id;
        uint32 gates;
        uint8 drawing;
        uint256 weight;
    }

    mapping(uint256 => Stake) public stakes;

    function set(uint256 id, address who) external {
        stakes[id] = Stake(who, uint32(id), 40, 9, 1);
    }
}

contract MockWrapperV2 {
    mapping(address => mapping(uint256 => uint256)) public wrapperOf;
    mapping(uint256 => address) public ownerOf;

    function set(uint256 circuitId, uint256 tokenId, address who) external {
        wrapperOf[address(0)][circuitId] = tokenId; // caller uses actual cpu below
        ownerOf[tokenId] = who;
    }

    // Test helper with explicit cpu key.
    function setFor(address cpu, uint256 circuitId, uint256 tokenId, address who) external {
        wrapperOf[cpu][circuitId] = tokenId;
        ownerOf[tokenId] = who;
    }
}

contract SeriesVoteV2Test is Test {
    SeriesVoteV2 vote;
    MockCircuitV2 cpu;
    MockEditionsV2 reg;
    MockStakingV2 staking;
    MockWrapperV2 wrapper;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        cpu = new MockCircuitV2();
        reg = new MockEditionsV2();
        staking = new MockStakingV2();
        wrapper = new MockWrapperV2();

        string[] memory opts = new string[](3);
        opts[0] = "REG8 + COUNTER8";
        opts[1] = "REGFILE 4x8 + REG8";
        opts[2] = "STACK8 + REG8";
        vote = new SeriesVoteV2(
            address(cpu),
            address(reg),
            address(staking),
            address(wrapper),
            1,
            opts
        );

        cpu.setOwner(1, alice);                  // direct
        cpu.setOwner(2, address(staking));       // staked by alice
        cpu.setOwner(3, address(wrapper));       // wrapped TFD by alice
        cpu.setOwner(4, bob);                    // direct, bob
        staking.set(2, alice);
        wrapper.setFor(address(cpu), 3, 900, alice);

        reg.set(1, 0, 1);
        reg.set(2, 1, 1);
        reg.set(3, 2, 1);
        reg.set(4, 0, 1);
    }

    function _one(uint256 id) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = id;
    }

    function testDirectStakedWrappedAllCount() public {
        vote.setOpen(true);
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;

        vm.prank(alice);
        vote.vote(1, ids);

        assertEq(vote.tally(1), 3);
        assertEq(vote.totalVotes(), 3);
        assertTrue(vote.voted(1));
        assertTrue(vote.voted(2));
        assertTrue(vote.voted(3));
    }

    function testStakedCardCannotVoteAgainAfterUnstakeOrTransfer() public {
        vote.setOpen(true);
        vm.prank(alice);
        vote.vote(1, _one(2));

        // simulate unstake: owner becomes bob and staking record cleared
        cpu.setOwner(2, bob);
        staking.set(2, address(0));

        vm.prank(bob);
        vm.expectRevert(SeriesVoteV2.AlreadyVoted.selector);
        vote.vote(1, _one(2));
    }

    function testWrappedCardCannotVoteAgainAfterUnwrapOrTransfer() public {
        vote.setOpen(true);
        vm.prank(alice);
        vote.vote(2, _one(3));

        // simulate unwrap: cpu owner becomes bob; wrapper token owner changes too
        cpu.setOwner(3, bob);
        wrapper.setFor(address(cpu), 3, 900, bob);

        vm.prank(bob);
        vm.expectRevert(SeriesVoteV2.AlreadyVoted.selector);
        vote.vote(2, _one(3));
    }

    function testDirectTransferAfterVoteCannotVote() public {
        vote.setOpen(true);
        vm.prank(alice);
        vote.vote(0, _one(1));
        cpu.setOwner(1, bob);

        vm.prank(bob);
        vm.expectRevert(SeriesVoteV2.AlreadyVoted.selector);
        vote.vote(0, _one(1));
    }

    function testTransferBeforeVoteNewOwnerCanVote() public {
        cpu.setOwner(1, bob);
        vote.setOpen(true);

        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.NotOwner.selector);
        vote.vote(0, _one(1));

        vm.prank(bob);
        vote.vote(0, _one(1));
        assertEq(vote.tally(0), 1);
    }

    function testOnlyHolderCanVote() public {
        vote.setOpen(true);
        vm.prank(bob);
        vm.expectRevert(SeriesVoteV2.NotOwner.selector);
        vote.vote(0, _one(1));
    }

    function testWrongEpochRejected() public {
        reg.set(1, 0, 2);
        vote.setOpen(true);
        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.WrongEpoch.selector);
        vote.vote(0, _one(1));
    }

    function testCannotVoteWhenClosed() public {
        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.Closed.selector);
        vote.vote(0, _one(1));
    }

    function testOnlyOwnerOpens() public {
        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.NotOwnerOfContract.selector);
        vote.setOpen(true);
    }

    function testBadChoiceRejected() public {
        vote.setOpen(true);
        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.BadChoice.selector);
        vote.vote(9, _one(1));
    }

    function testEmptyCardsRejected() public {
        vote.setOpen(true);
        uint256[] memory ids = new uint256[](0);
        vm.prank(alice);
        vm.expectRevert(SeriesVoteV2.NoCards.selector);
        vote.vote(0, ids);
    }

    function testStakingRecordIsUnchanged() public {
        vote.setOpen(true);
        vm.prank(alice);
        vote.vote(1, _one(2));
        (address staker,,,,) = staking.stakes(2);
        assertEq(staker, alice);
    }

    function testSameWalletCanUseOtherCards() public {
        vote.setOpen(true);
        vm.startPrank(alice);
        vote.vote(0, _one(1));
        vote.vote(1, _one(2));
        vote.vote(2, _one(3));
        vm.stopPrank();
        assertEq(vote.totalVotes(), 3);
        assertEq(vote.tally(0), 1);
        assertEq(vote.tally(1), 1);
        assertEq(vote.tally(2), 1);
    }
}
