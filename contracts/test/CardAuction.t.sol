// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CardAuction} from "../src/CardAuction.sol";

contract Mock721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setApprovalForAll(address o, bool ok) external { isApprovedForAll[msg.sender][o] = ok; }
    function transferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
    }
}

contract MockBEM {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract CardAuctionTest is Test {
    CardAuction market;
    Mock721 cards;
    MockBEM bem;
    address treasury = address(0xFEE);
    address seller = address(0x5E11);
    address a = address(0xA1);
    address b = address(0xB2);
    uint256 constant ID = 7;
    uint96 constant RESERVE = 100e8;

    function setUp() public {
        cards = new Mock721();
        bem = new MockBEM();
        market = new CardAuction(address(cards), address(bem), treasury);
        cards.mint(seller, ID);
        vm.prank(seller);
        cards.setApprovalForAll(address(market), true);
        bem.mint(a, 10_000e8);
        bem.mint(b, 10_000e8);
        vm.prank(a); bem.approve(address(market), type(uint256).max);
        vm.prank(b); bem.approve(address(market), type(uint256).max);
    }

    function _create() internal {
        vm.prank(seller);
        market.createAuction(ID, RESERVE, 1 hours);
    }

    function testCreateEscrowsCard() public {
        _create();
        assertEq(cards.ownerOf(ID), address(market));
        (address s,,,,,,) = market.auctions(ID);
        assertEq(s, seller);
    }

    function testBidBelowReserveReverts() public {
        _create();
        vm.prank(a);
        vm.expectRevert(CardAuction.TooLow.selector);
        market.bid(ID, RESERVE - 1);
    }

    function testOutbidCreditsPrevious() public {
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.prank(b); market.bid(ID, 105e8);
        assertEq(market.credits(a), 100e8);
        uint256 before = bem.balanceOf(a);
        vm.prank(a); market.withdraw();
        assertEq(bem.balanceOf(a) - before, 100e8);
    }

    function testSettleTransfersCardAndPays() public {
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = bem.balanceOf(seller);
        market.settle(ID);
        assertEq(cards.ownerOf(ID), a);
        assertEq(bem.balanceOf(seller) - before, 100e8);
    }

    function testFeeGoesToTreasury() public {
        market.setFee(250);
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 beforeT = bem.balanceOf(treasury);
        uint256 beforeS = bem.balanceOf(seller);
        market.settle(ID);
        assertEq(bem.balanceOf(treasury) - beforeT, 2.5e8);
        assertEq(bem.balanceOf(seller) - beforeS, 97.5e8);
    }

    function testOnePercentFee() public {
        market.setFee(100);
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 beforeT = bem.balanceOf(treasury);
        uint256 beforeS = bem.balanceOf(seller);
        market.settle(ID);
        assertEq(bem.balanceOf(treasury) - beforeT, 1e8);   // 1%
        assertEq(bem.balanceOf(seller) - beforeS, 99e8);
    }

    function testAntiSnipeExtends() public {
        _create();
        vm.warp(block.timestamp + 1 hours - 60);
        vm.prank(a); market.bid(ID, 100e8);
        (, , , , uint64 endAt, ,) = market.auctions(ID);
        assertEq(endAt, block.timestamp + 5 minutes);
    }

    function testCancelBeforeBidReturnsCard() public {
        _create();
        vm.prank(seller); market.cancel(ID);
        assertEq(cards.ownerOf(ID), seller);
    }

    function testCancelWithBidReverts() public {
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.prank(seller);
        vm.expectRevert(CardAuction.HasBids.selector);
        market.cancel(ID);
    }

    function testSellerCannotBid() public {
        _create();
        vm.prank(seller);
        vm.expectRevert(CardAuction.SellerCannotBid.selector);
        market.bid(ID, 100e8);
    }

    function testSettleBeforeEndReverts() public {
        _create();
        vm.prank(a); market.bid(ID, 100e8);
        vm.expectRevert(CardAuction.NotEnded.selector);
        market.settle(ID);
    }
}
