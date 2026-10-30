// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TapeFoundryOfferBook} from "../src/CardOfferBook.sol";

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external {
        ownerOf[id] = to;
    }

    function setOwner(uint256 id, address to) external {
        ownerOf[id] = to;
    }

    function setApprovalForAll(address operator, bool ok) external {
        isApprovedForAll[msg.sender][operator] = ok;
    }

    function transferFrom(address from, address to, uint256 id) public {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        ownerOf[id] = to;
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        transferFrom(from, to, id);
    }
}

contract MockRegistry {
    struct Edition {
        uint16 epoch;
        uint8 drawing;
        uint16 number;
    }

    mapping(address => mapping(uint256 => Edition)) public editions;

    function setEdition(address cpu, uint256 id, uint16 number) external {
        editions[cpu][id] = Edition(1, 1, number);
    }

    function editionOf(address cpu, uint256 id) external view returns (uint16, uint8, uint16) {
        Edition memory e = editions[cpu][id];
        return (e.epoch, e.drawing, e.number);
    }
}

contract CardOfferBookTest is Test {
    TapeFoundryOfferBook book;
    MockERC20 bem;
    MockERC721 cards;
    MockRegistry registry;

    address treasury = address(0xFEE);
    address seller = address(0x5E11);
    address buyer = address(0xB0B);
    uint256 constant TOKEN = 44;
    uint96 constant PRICE = 100e8;

    function setUp() public {
        bem = new MockERC20();
        cards = new MockERC721();
        registry = new MockRegistry();
        book = new TapeFoundryOfferBook(address(bem), address(cards), address(registry), treasury);

        cards.mint(seller, TOKEN);
        registry.setEdition(address(cards), TOKEN, 21);
        bem.mint(buyer, 1_000e8);

        vm.prank(buyer);
        bem.approve(address(book), type(uint256).max);
        vm.prank(seller);
        cards.setApprovalForAll(address(book), true);
    }

    function _offer(uint96 amount, uint64 expiresAt) internal returns (uint256 id) {
        vm.prank(buyer);
        id = book.createOffer(TOKEN, amount, expiresAt);
    }

    function testCreateAndAccept() public {
        uint64 expiry = uint64(block.timestamp + 1 days);
        uint256 id = _offer(PRICE, expiry);

        assertEq(book.activeOfferOf(buyer, TOKEN), id);
        assertEq(bem.balanceOf(address(book)), PRICE);

        uint256 sellerBefore = bem.balanceOf(seller);
        vm.prank(seller);
        book.acceptOffer(id);

        assertEq(cards.ownerOf(TOKEN), buyer);
        assertEq(bem.balanceOf(treasury), PRICE / 100); // 1%
        assertEq(bem.balanceOf(seller) - sellerBefore, PRICE - PRICE / 100);
        assertEq(book.activeOfferOf(buyer, TOKEN), 0);
    }

    function testCancelRefundsBuyer() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        uint256 before = bem.balanceOf(buyer);

        vm.prank(buyer);
        book.cancelOffer(id);

        assertEq(bem.balanceOf(buyer) - before, PRICE);
        assertEq(book.activeOfferOf(buyer, TOKEN), 0);
        assertEq(cards.ownerOf(TOKEN), seller);
    }

    function testExpiredCannotBeAccepted() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);

        vm.prank(seller);
        vm.expectRevert(TapeFoundryOfferBook.Expired.selector);
        book.acceptOffer(id);
    }

    function testBuyerCanRefundAfterExpiry() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 1 hours + 1);
        uint256 before = bem.balanceOf(buyer);

        vm.prank(buyer);
        book.cancelOffer(id);
        assertEq(bem.balanceOf(buyer) - before, PRICE);
    }

    function testOnlyCurrentOwnerCanAccept() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        // Simulate a card that is in the auction market / staking / wrapper.
        cards.setOwner(TOKEN, address(0x1234));

        vm.prank(seller);
        vm.expectRevert(TapeFoundryOfferBook.NotOwner.selector);
        book.acceptOffer(id);
    }

    function testCannotOfferOnUnnumberedCard() public {
        registry.setEdition(address(cards), TOKEN, 0);
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryOfferBook.NotNumbered.selector);
        book.createOffer(TOKEN, PRICE, uint64(block.timestamp + 1 days));
    }

    function testOneActiveOfferPerBuyerPerToken() public {
        _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryOfferBook.OfferExists.selector);
        book.createOffer(TOKEN, PRICE, uint64(block.timestamp + 2 days));
    }

    function testOnlyBuyerCanCancel() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        vm.expectRevert(TapeFoundryOfferBook.NotBuyer.selector);
        book.cancelOffer(id);
    }

    function testSelfTradeRejected() public {
        uint256 id = _offer(PRICE, uint64(block.timestamp + 1 days));
        cards.setOwner(TOKEN, buyer);
        vm.prank(buyer);
        cards.setApprovalForAll(address(book), true);
        vm.prank(buyer);
        vm.expectRevert(TapeFoundryOfferBook.SelfTrade.selector);
        book.acceptOffer(id);
    }

    function testFeeRoundsDown() public {
        uint96 amount = 101; // 1% => 1
        uint256 id = _offer(amount, uint64(block.timestamp + 1 days));
        vm.prank(seller);
        book.acceptOffer(id);
        assertEq(bem.balanceOf(treasury), 1);
    }
}
