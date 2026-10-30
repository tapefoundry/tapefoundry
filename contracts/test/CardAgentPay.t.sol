// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CardAgentPay} from "../src/CardAgentPay.sol";

contract MockBEM {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        require(balanceOf[f] >= a && allowance[f][msg.sender] >= a, "allow");
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[t] += a;
        return true;
    }
}

contract MockCard {
    mapping(uint256 => address) public ownerOf;
    function mint(address to, uint256 id) external { ownerOf[id] = to; }
}

contract CardAgentPayTest is Test {
    MockBEM bem;
    MockCard cards;
    CardAgentPay pay;
    address treasury = address(0x7EA5);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        bem = new MockBEM();
        cards = new MockCard();
        pay = new CardAgentPay(address(bem), address(cards), treasury, 50_000_000); // 0.5 BEM
        cards.mint(alice, 6);
        bem.mint(bob, 100_000_000);
        vm.prank(bob);
        bem.approve(address(pay), type(uint256).max);
    }

    function testAskSplits70_30() public {
        vm.prank(bob);
        pay.ask(6);
        assertEq(bem.balanceOf(alice), 35_000_000);
        assertEq(bem.balanceOf(treasury), 15_000_000);
        assertEq(bem.balanceOf(bob), 50_000_000);
    }

    function testOnlyOwnerSetsPrice() public {
        vm.prank(bob);
        vm.expectRevert("owner");
        pay.setPrice(1);
    }

    function testCannotAskWithoutApproval() public {
        MockBEM b2 = new MockBEM();
        b2.mint(bob, 1_000_000);
        CardAgentPay p2 = new CardAgentPay(address(b2), address(cards), treasury, 50_000_000);
        vm.prank(bob);
        vm.expectRevert("allow");
        p2.ask(6);
    }
}
