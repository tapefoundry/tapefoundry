// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TapeFoundryDrawingOfferBook} from "../src/DrawingOfferBook.sol";

contract D20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount; return true;
    }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

contract D721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function setOwner(uint256 id, address to) external { ownerOf[id] = to; }
    function setApprovalForAll(address operator, bool ok) external { isApprovedForAll[msg.sender][operator] = ok; }
    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
    }
    function safeTransferFrom(address from, address to, uint256 id) external { transferFrom(from, to, id); }
}

contract DReg {
    struct Edition { uint16 epoch; uint8 drawing; uint16 number; }
    mapping(address => mapping(uint256 => Edition)) public editions;

    function setEdition(address cpu, uint256 id, uint8 drawing, uint16 number) external {
        editions[cpu][id] = Edition(1, drawing, number);
    }
    function editionOf(address cpu, uint256 id) external view returns (uint16, uint8, uint16) {
        Edition memory e = editions[cpu][id];
        return (e.epoch, e.drawing, e.number);
    }
}

contract DrawingOfferBookTest is Test {
    TapeFoundryDrawingOfferBook book;
    D20 bem;
    D721 cards;
    DReg registry;

    address treasury = address(0xFEE);
    address seller = address(0x5E11);
    address buyer = address(0xB0B);
    uint256 constant TOKEN_A = 44;
    uint256 constant TOKEN_B = 45; // another card of the same drawing
    uint256 constant TOKEN_C = 46; // a different drawing
    uint8 constant DRAWING = 1;
    uint96 constant PRICE = 100e8;

    function setUp() public {
        bem = new D20();
        cards = new D721();
        registry = new DReg();
        book = new TapeFoundryDrawingOfferBook(address(bem), address(cards), address(registry), treasury);

        cards.mint(seller, TOKEN_A);
        cards.mint(seller, TOKEN_B);
        cards.mint(seller, TOKEN_C);
        registry.setEdition(address(cards), TOKEN_A, DRAWING, 1);
        registry.setEdition(address(cards), TOKEN_B, DRAWING, 2);
        registry.setEdition(address(cards), TOKEN_C, 2, 1);
        bem.mint(buyer, 1_000e8);

        vm.prank(buyer);
        bem.approve(address(book), type(uint256).max);
        vm.prank(seller);
        cards.setApprovalForAll(address(book), true);
    }

    function _offer(uint96 amount, uint64 expiresAt) internal returns (uint256) {
        vm.prank(buyer);
        return book.createOffer(DRAWING, amount, expiresAt);
    }

    function testAcceptAnyCardOfDrawing() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        uint256 sellerBefore = bem.balanceOf(seller);

        vm.prank(seller);
        book.acceptOffer(id, TOKEN_B);

        assertEq(cards.ownerOf(TOKEN_B), buyer);
        assertEq(cards.ownerOf(TOKEN_A), seller);
        assertEq(bem.balanceOf(treasury), PRICE / 100);
        assertEq(bem.balanceOf(seller) - sellerBefore, PRICE - PRICE / 100);
        assertEq(book.activeOfferOf(buyer, DRAWING), 0);
    }

    function testWrongDrawingRejected() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        vm.expectRevert(TapeFoundryDrawingOfferBook.WrongDrawing.selector);
        book.acceptOffer(id, TOKEN_C);
    }

    function testUnnumberedCardRejected() public {
        registry.setEdition(address(cards), TOKEN_B, DRAWING, 0);
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        vm.expectRevert(TapeFoundryDrawingOfferBook.NotNumbered.selector);
        book.acceptOffer(id, TOKEN_B);
    }

    function testCancelRefundsBuyer() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        uint256 before = bem.balanceOf(buyer);
        vm.prank(buyer);
        book.cancelOffer(id);
        assertEq(bem.balanceOf(buyer) - before, PRICE);
        assertEq(book.activeOfferOf(buyer, DRAWING), 0);
    }

    function testBuyerCanRefundAfterExpiry() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = bem.balanceOf(buyer);
        vm.prank(buyer);
        book.cancelOffer(id);
        assertEq(bem.balanceOf(buyer) - before, PRICE);
    }

    function testExpiredCannotBeAccepted() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(seller);
        vm.expectRevert(TapeFoundryDrawingOfferBook.Expired.selector);
        book.acceptOffer(id, TOKEN_A);
    }

    function testOnlyCurrentOwnerCanAccept() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        cards.setOwner(TOKEN_A, address(0x1234));
        vm.prank(seller);
        vm.expectRevert(TapeFoundryDrawingOfferBook.NotOwner.selector);
        book.acceptOffer(id, TOKEN_A);
    }

    function testOneActiveOfferPerBuyerPerDrawing() public {
        _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryDrawingOfferBook.OfferExists.selector);
        book.createOffer(DRAWING, PRICE, uint64(block.timestamp + 2 days));
    }

    function testBadDrawingRejected() public {
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryDrawingOfferBook.BadDrawing.selector);
        book.createOffer(11, PRICE, uint64(block.timestamp + 1 days));
    }

    function testOnlyBuyerCanCancel() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        vm.expectRevert(TapeFoundryDrawingOfferBook.NotBuyer.selector);
        book.cancelOffer(id);
    }

    function testSelfTradeRejected() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        cards.setOwner(TOKEN_B, buyer);
        vm.prank(buyer);
        cards.setApprovalForAll(address(book), true);
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryDrawingOfferBook.SelfTrade.selector);
        book.acceptOffer(id, TOKEN_B);
    }

    function testFeeRoundsDown() public {
        uint96 amount = 101;
        uint256 id = _offer(amount, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        book.acceptOffer(id, TOKEN_A);
        assertEq(bem.balanceOf(treasury), 1);
    }
}
