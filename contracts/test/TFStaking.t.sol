// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TapeFoundryToken} from "../src/TapeFoundryToken.sol";
import {TFStakingSeason1} from "../src/TFStakingSeason1.sol";

contract MockCard is ERC721 {
    mapping(uint256 => uint32) public gates;
    constructor() ERC721("Card", "CARD") {}
    function mint(address to, uint256 id, uint32 g) external {
        gates[id] = g;
        _mint(to, id);
    }
    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        return (1, 1, 0, gates[id]);
    }
}

contract MockRegistry {
    mapping(uint256 => uint8) public drawing;
    function setDrawing(uint256 id, uint8 d) external { drawing[id] = d; }
    function editionOf(address, uint256 id) external view returns (uint16, uint8, uint16) {
        return (0, drawing[id], 0);
    }
}

contract TFStakingTest is Test {
    TapeFoundryToken tf;
    MockCard card;
    MockRegistry reg;
    TFStakingSeason1 staking;
    uint64 start;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        tf = new TapeFoundryToken(address(this), address(this));
        card = new MockCard();
        reg = new MockRegistry();
        start = uint64(block.timestamp + 1 days);
        address[] memory ex = new address[](0);
        staking = new TFStakingSeason1(tf, card, address(card), address(reg), start, ex);
        tf.transfer(address(staking), 270_000 ether);

        for (uint256 i = 1; i <= 3; i++) {
            card.mint(alice, i, 100);
            vm.prank(alice);
            card.approve(address(staking), i);
        }
    }

    function testThreeCardGate() public {
        vm.startPrank(alice);
        staking.stake(1);
        staking.stake(2);
        assertEq(staking.weightOf(alice), 0);
        vm.warp(start + 1 days);
        assertEq(staking.pendingOf(alice), 0);

        staking.stake(3);
        assertEq(staking.weightOf(alice), 30e9);
        vm.stopPrank();
    }

    function testOneDayShare() public {
        vm.startPrank(alice);
        staking.stake(1);
        staking.stake(2);
        staking.stake(3);
        vm.warp(start + 1 days);
        assertEq(staking.pendingOf(alice), 33_750 ether);
        staking.claim();
        assertEq(tf.balanceOf(alice), 33_750 ether);
        assertEq(staking.pendingOf(alice), 0);
        vm.stopPrank();
    }

    function testOneSecondIsClaimable() public {
        vm.startPrank(alice);
        staking.stake(1);
        staking.stake(2);
        staking.stake(3);
        vm.warp(start + 1);
        uint256 p = staking.pendingOf(alice);
        assertGt(p, 0);
        staking.claim();
        assertEq(tf.balanceOf(alice), p);
        vm.stopPrank();
    }

    function testHalfDayThenUnstake() public {
        vm.startPrank(alice);
        staking.stake(1);
        staking.stake(2);
        staking.stake(3);
        vm.warp(start + 12 hours);
        uint256 p = staking.pendingOf(alice);
        assertApproxEqAbs(p, 16_875 ether, 1 ether);
        staking.claim();
        staking.unstake(1);
        assertEq(card.ownerOf(1), alice);
        assertEq(staking.weightOf(alice), 0);
        vm.stopPrank();
    }

    function testSetBonus() public {
        // 11 distinct drawings, each 100 gates.
        for (uint256 i = 1; i <= 11; i++) {
            reg.setDrawing(i, uint8(i));
            if (i > 3) {
                card.mint(alice, i, 100);
                vm.prank(alice);
                card.approve(address(staking), i);
            }
        }
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 11; i++) {
            staking.stake(i);
        }
        // 11 * sqrt(100)*1e9 = 110e9, plus 50e9 set bonus.
        assertEq(staking.weightOf(alice), 160e9);
        vm.stopPrank();
    }

    function testNoDoubleStake() public {
        vm.startPrank(alice);
        staking.stake(1);
        vm.expectRevert(bytes("already staked"));
        staking.stake(1);
        vm.stopPrank();
    }

    function testOnlyOwnerCanStake() public {
        vm.prank(bob);
        vm.expectRevert(bytes("not owner"));
        staking.stake(1);
    }

    function testExcluded() public {
        address[] memory ex = new address[](1);
        ex[0] = alice;
        TFStakingSeason1 s2 = new TFStakingSeason1(tf, card, address(card), address(reg), start, ex);
        vm.prank(alice);
        vm.expectRevert(bytes("excluded"));
        s2.stake(1);
    }


    function _mintCards(uint256 n) internal returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i = 1; i <= n; i++) {
            if (i > 3) card.mint(alice, i, 100);
            ids[i - 1] = i;
        }
        vm.prank(alice);
        card.setApprovalForAll(address(staking), true);
    }

    function testBatchStakeFifty() public {
        uint256[] memory ids = _mintCards(50);
        vm.prank(alice);
        staking.stakeMany(ids);
        assertEq(staking.stakedCount(alice), 50);
        assertEq(staking.weightOf(alice), 500e9);
        assertEq(card.ownerOf(50), address(staking));
    }

    function testBatchUnstake() public {
        uint256[] memory ids = _mintCards(5);
        vm.startPrank(alice);
        staking.stakeMany(ids);
        uint256 before = staking.weightOf(alice);
        assertEq(before, 50e9);
        staking.unstakeMany(ids);
        assertEq(staking.weightOf(alice), 0);
        assertEq(card.ownerOf(1), alice);
        assertEq(card.ownerOf(5), alice);
        vm.stopPrank();
    }

    function testBatchDuplicateReverts() public {
        _mintCards(3);
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1; ids[1] = 1;
        vm.prank(alice);
        vm.expectRevert(bytes("already staked"));
        staking.stakeMany(ids);
    }

    function testBatchTooLargeReverts() public {
        uint256[] memory ids = new uint256[](51);
        vm.prank(alice);
        vm.expectRevert(bytes("batch too large"));
        staking.stakeMany(ids);
    }

    function testSeasonStopsAtFifteenDays() public {
        vm.startPrank(alice);
        staking.stake(1);
        staking.stake(2);
        staking.stake(3);
        vm.warp(start + 20 days);
        assertEq(staking.pendingOf(alice), 270_000 ether);
        staking.claim();
        assertEq(tf.balanceOf(alice), 270_000 ether);
        vm.stopPrank();
    }
}
