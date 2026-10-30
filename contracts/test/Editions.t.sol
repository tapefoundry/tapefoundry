// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TapeFoundryEditions, IProcessor} from "../src/TapeFoundryEditions.sol";

/// 假的处理器：只实现合约用到的两个方法，行为可控
contract MockProcessor is IProcessor {
    mapping(uint256 => address) public holder;
    mapping(uint256 => bytes) internal nl;

    function set(uint256 id, address who, bytes calldata bytes_) external {
        holder[id] = who;
        nl[id] = bytes_;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return holder[id];
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return nl[id];
    }
}

contract EditionsTest is Test {
    TapeFoundryEditions reg;
    MockProcessor cpu;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    bytes constant NOT_NL = hex"00000002000002";
    bytes32 constant NOT_HASH = keccak256(NOT_NL);

    function setUp() public {
        reg = new TapeFoundryEditions();
        cpu = new MockProcessor();
        reg.setProcessor(address(cpu), true);
        reg.register(0, 1, NOT_HASH, 3);      // 只有 3 份，便于测售罄
    }

    function testClaimGivesSequentialNumbers() public {
        cpu.set(1, alice, NOT_NL);
        cpu.set(2, bob, NOT_NL);

        vm.prank(alice);
        assertEq(reg.claim(0, 1, address(cpu), 1), 1);

        vm.prank(bob);
        assertEq(reg.claim(0, 1, address(cpu), 2), 2);

        (uint16 epoch, uint8 drawing, uint16 number) = reg.editionOf(address(cpu), 2);
        assertEq(epoch, 0);
        assertEq(drawing, 1);
        assertEq(number, 2);
        assertEq(reg.remaining(0, 1), 1);
    }

    function testRevertWhenNotHolder() public {
        cpu.set(1, alice, NOT_NL);
        vm.prank(bob);
        vm.expectRevert(TapeFoundryEditions.NotHolder.selector);
        reg.claim(0, 1, address(cpu), 1);
    }

    function testRevertWhenHashMismatch() public {
        cpu.set(1, alice, hex"deadbeef");
        vm.prank(alice);
        vm.expectRevert(TapeFoundryEditions.HashMismatch.selector);
        reg.claim(0, 1, address(cpu), 1);
    }

    function testRevertOnDoubleClaim() public {
        cpu.set(1, alice, NOT_NL);
        vm.startPrank(alice);
        reg.claim(0, 1, address(cpu), 1);
        vm.expectRevert(TapeFoundryEditions.AlreadyClaimed.selector);
        reg.claim(0, 1, address(cpu), 1);
        vm.stopPrank();
    }

    function testSoldOutAtMax() public {
        for (uint256 i = 1; i <= 3; i++) {
            cpu.set(i, alice, NOT_NL);
            vm.prank(alice);
            reg.claim(0, 1, address(cpu), i);
        }
        cpu.set(4, alice, NOT_NL);
        vm.prank(alice);
        vm.expectRevert(TapeFoundryEditions.SoldOut.selector);
        reg.claim(0, 1, address(cpu), 4);
        assertEq(reg.remaining(0, 1), 0);
    }

    function testRevertIfProcessorNotAllowed() public {
        MockProcessor other = new MockProcessor();
        other.set(1, alice, NOT_NL);
        vm.prank(alice);
        vm.expectRevert(TapeFoundryEditions.NotProcessor.selector);
        reg.claim(0, 1, address(other), 1);
    }

    function testRevertIfDrawingNotRegistered() public {
        cpu.set(1, alice, NOT_NL);
        vm.prank(alice);
        vm.expectRevert(TapeFoundryEditions.NotDrawing.selector);
        reg.claim(0, 9, address(cpu), 1);
    }

    function testOnlyOwnerCanRegister() public {
        vm.prank(alice);
        vm.expectRevert(TapeFoundryEditions.NotOwner.selector);
        reg.register(0, 2, NOT_HASH, 100);
    }

    function testEpochsAreIndependent() public {
        cpu.set(1, alice, NOT_NL);
        vm.prank(alice);
        assertEq(reg.claim(0, 1, address(cpu), 1), 1);

        reg.register(1, 1, NOT_HASH, 100);
        cpu.set(2, bob, NOT_NL);
        vm.prank(bob);
        assertEq(reg.claim(1, 1, address(cpu), 2), 1);   // 新一期从 1 开始
    }
}
