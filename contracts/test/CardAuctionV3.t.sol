// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CardAuctionV3} from "../src/CardAuctionV3.sol";

contract M721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;
    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setApprovalForAll(address o, bool ok) external { isApprovedForAll[msg.sender][o] = ok; }
    function transferFrom(address f, address to, uint256 id) external {
        require(ownerOf[id] == f && (msg.sender == f || isApprovedForAll[f][msg.sender]), "no");
        ownerOf[id] = to;
    }
}

contract M20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract V3Test is Test {
    CardAuctionV3 market;
    M721 cards;
    M20 bem;
    address treasury = address(0xFEE);
    address seller = address(0x5E11);
    address buyer = address(0xB0B);
    uint256 constant A = 1;
    uint256 constant B = 2;

    function setUp() public {
        cards = new M721(); bem = new M20();
        market = new CardAuctionV3(address(cards), address(bem), treasury);
        market.setFee(100);
        cards.mint(seller, A); cards.mint(seller, B);
        vm.startPrank(seller);
        cards.setApprovalForAll(address(market), true);
        vm.stopPrank();
        bem.mint(buyer, 1_000e8);
        vm.prank(buyer); bem.approve(address(market), type(uint256).max);
    }

    function _list(uint256 id, uint96 reserve, uint96 buyNow) internal {
        vm.prank(seller);
        market.createAuction(id, reserve, 1 hours, buyNow);
    }

    function testBuyAtBuyNow() public {
        _list(A, 100e8, 200e8);
        uint256 before = bem.balanceOf(seller);
        vm.prank(buyer); market.buy(A);
        assertEq(cards.ownerOf(A), buyer);
        assertEq(bem.balanceOf(seller) - before, 198e8);
        assertEq(bem.balanceOf(treasury), 2e8);
    }

    function testSweepTwo() public {
        _list(A, 100e8, 200e8);
        _list(B, 100e8, 300e8);
        uint256 before = bem.balanceOf(buyer);
        uint256[] memory ids = new uint256[](2);
        ids[0] = A; ids[1] = B;
        vm.prank(buyer); market.sweep(ids);
        assertEq(cards.ownerOf(A), buyer);
        assertEq(cards.ownerOf(B), buyer);
        assertEq(before - bem.balanceOf(buyer), 500e8);
        assertEq(bem.balanceOf(treasury), 5e8);
    }

    function testCannotBuyOwn() public {
        _list(A, 100e8, 200e8);
        vm.prank(seller);
        vm.expectRevert(CardAuctionV3.NotSeller.selector);
        market.buy(A);
    }

    function testNoBuyNowReverts() public {
        _list(A, 100e8, 0);
        vm.prank(buyer);
        vm.expectRevert(CardAuctionV3.NotForSale.selector);
        market.buy(A);
    }

    function testBidAboveBuyNowRejected() public {
        _list(A, 100e8, 200e8);
        vm.prank(buyer);
        vm.expectRevert(CardAuctionV3.TooLow.selector);
        market.bid(A, 200e8);
    }

    function testAuctionStillWorks() public {
        _list(A, 100e8, 0);
        vm.prank(buyer); market.bid(A, 100e8);
        vm.warp(block.timestamp + 1 hours + 1);
        market.settle(A);
        assertEq(cards.ownerOf(A), buyer);
    }
}
