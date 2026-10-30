// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CardAuctionV4} from "../src/CardAuctionV4.sol";

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

contract V4Test is Test {
    CardAuctionV4 market;
    M721 cards;
    M20 bem;
    address treasury = address(0xFEE);
    address royalty = address(0xA11CE);
    address seller = address(0x5E11);
    address buyer = address(0xB0B);
    uint256 constant A = 1;

    function setUp() public {
        cards = new M721(); bem = new M20();
        market = new CardAuctionV4(address(bem), treasury);
        market.addCollection(address(cards), 100, 500, royalty);
        cards.mint(seller, A);
        vm.startPrank(seller);
        cards.setApprovalForAll(address(market), true);
        vm.stopPrank();
        bem.mint(buyer, 1_000e8);
        vm.prank(buyer); bem.approve(address(market), type(uint256).max);
    }

    function _list(uint96 reserve, uint96 buyNow) internal {
        vm.prank(seller);
        market.createAuction(address(cards), A, reserve, 1 hours, buyNow);
    }

    function testBuyFeeAndRoyalty() public {
        _list(100e8, 200e8);
        uint256 s0 = bem.balanceOf(seller);
        vm.prank(buyer); market.buy(address(cards), A);
        assertEq(cards.ownerOf(A), buyer);
        assertEq(bem.balanceOf(treasury), 2e8);       // 1%
        assertEq(bem.balanceOf(royalty), 10e8);       // 5%
        assertEq(bem.balanceOf(seller) - s0, 188e8);  // 94%
    }

    function testSweepTwo() public {
        uint256 B = 2;
        cards.mint(seller, B);
        _list(100e8, 200e8);
        vm.prank(seller); market.createAuction(address(cards), B, 100e8, 1 hours, 200e8);
        uint256[] memory ids = new uint256[](2); ids[0]=A; ids[1]=B;
        uint256 b0 = bem.balanceOf(buyer);
        vm.prank(buyer); market.sweep(address(cards), ids);
        assertEq(cards.ownerOf(A), buyer);
        assertEq(cards.ownerOf(B), buyer);
        assertEq(b0 - bem.balanceOf(buyer), 400e8);
        assertEq(bem.balanceOf(treasury), 4e8);
    }

    function testUnlistedCollectionRejected() public {
        M721 other = new M721(); other.mint(seller, 9);
        vm.startPrank(seller);
        other.setApprovalForAll(address(market), true);
        vm.expectRevert(CardAuctionV4.NotAllowed.selector);
        market.createAuction(address(other), 9, 1e8, 1 hours, 0);
        vm.stopPrank();
    }

    function testOwnerOnlyAddCollection() public {
        vm.prank(buyer);
        vm.expectRevert(CardAuctionV4.NotOwner.selector);
        market.addCollection(address(0x1234), 100, 0, address(0));
    }

    function testAuctionStillWorks() public {
        _list(100e8, 0);
        vm.prank(buyer); market.bid(address(cards), A, 100e8);
        vm.warp(block.timestamp + 1 hours + 1);
        market.settle(address(cards), A);
        assertEq(cards.ownerOf(A), buyer);
    }

    function testCannotBuyOwn() public {
        _list(100e8, 200e8);
        vm.prank(seller);
        vm.expectRevert(CardAuctionV4.NotSeller.selector);
        market.buy(address(cards), A);
    }
}
