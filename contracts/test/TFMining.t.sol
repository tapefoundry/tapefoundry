// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TapeFoundryToken} from "../src/TapeFoundryToken.sol";
import {EcosystemVesting} from "../src/EcosystemVesting.sol";
import {TFMiningSeason1} from "../src/TFMiningSeason1.sol";

contract TFMiningTest is Test {
    TapeFoundryToken tf;
    TFMiningSeason1 mining;
    EcosystemVesting vesting;
    uint64 start;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        tf = new TapeFoundryToken(address(this), address(this));
        start = uint64(block.timestamp + 1 days);
        mining = new TFMiningSeason1(tf, start, address(this));
        tf.transfer(address(mining), 270_000 ether);

        vesting = new EcosystemVesting(tf, alice, uint64(block.timestamp), 100_000 ether);
        tf.transfer(address(vesting), 100_000 ether);
    }

    function _leaf(uint8 d, address who, uint256 weight) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(d, who, weight));
    }

    function testFixedSupply() public view {
        assertEq(tf.totalSupply(), 1_000_000 ether);
        assertEq(tf.MAX_SUPPLY(), 1_000_000 ether);
        assertEq(tf.balanceOf(address(this)), 630_000 ether);
    }

    function testNoTransferTax() public {
        tf.transfer(bob, 100 ether);
        assertEq(tf.balanceOf(bob), 100 ether);
    }

    function testDayPoolsSumToTotal() public view {
        uint256 sum;
        for (uint8 d = 1; d <= 15; d++) {
            sum += mining.dayPool(d);
        }
        assertEq(sum, 270_000 ether);
        assertEq(mining.dayPool(1), 33_750 ether);
        assertEq(mining.dayPool(15), 2_250 ether);
    }

    function testPublishOnlyAfterStartAndPublisher() public {
        bytes32 root = _leaf(1, alice, 1000);
        vm.expectRevert(bytes("too early"));
        mining.publishDay(1, root, 1000);

        vm.warp(start);
        vm.prank(bob);
        vm.expectRevert(bytes("not publisher"));
        mining.publishDay(1, root, 1000);

        mining.publishDay(1, root, 1000);
        (, , uint256 pool, bool published) = mining.dayInfo(1);
        assertTrue(published);
        assertEq(pool, 33_750 ether);
    }

    function testClaimOneLeaf() public {
        vm.warp(start);
        bytes32 root = _leaf(1, alice, 1000);
        mining.publishDay(1, root, 10_000);

        vm.prank(alice);
        mining.claim(1, 1000, new bytes32[](0));
        assertEq(tf.balanceOf(alice), 3_375 ether);
        assertTrue(mining.claimed(1, alice));
    }

    function testCannotDoubleClaim() public {
        vm.warp(start);
        bytes32 root = _leaf(1, alice, 1000);
        mining.publishDay(1, root, 10_000);

        vm.prank(alice);
        mining.claim(1, 1000, new bytes32[](0));
        vm.prank(alice);
        vm.expectRevert(bytes("already claimed"));
        mining.claim(1, 1000, new bytes32[](0));
    }

    function testBadProof() public {
        vm.warp(start);
        bytes32 root = _leaf(1, alice, 1000);
        mining.publishDay(1, root, 10_000);

        vm.prank(bob);
        vm.expectRevert(bytes("bad proof"));
        mining.claim(1, 1000, new bytes32[](0));
    }

    function testCapIsEnforced() public {
        // Extra seasons must be deployed while `start` is still in the future.
        TFMiningSeason1 bad = new TFMiningSeason1(tf, start, address(this));
        TFMiningSeason1 good = new TFMiningSeason1(tf, start, address(this));
        tf.transfer(address(bad), 270_000 ether);
        tf.transfer(address(good), 270_000 ether);

        vm.warp(start);
        bad.publishDay(1, _leaf(1, alice, 1201), 10_000);
        vm.prank(alice);
        vm.expectRevert(bytes("over cap"));
        bad.claim(1, 1201, new bytes32[](0));

        good.publishDay(1, _leaf(1, alice, 1200), 10_000);
        vm.prank(alice);
        good.claim(1, 1200, new bytes32[](0));
        assertEq(tf.balanceOf(alice), 4050 ether);
    }

    function testVestingLinear() public {
        assertEq(vesting.vested(), 0);
        vm.warp(block.timestamp + 365 days);
        uint256 half = vesting.vested();
        assertApproxEqAbs(half, 50_000 ether, 1 ether);
        vesting.release();
        assertApproxEqAbs(tf.balanceOf(alice), half, 1);

        vm.warp(block.timestamp + 365 days);
        uint256 rest = vesting.releasable();
        vesting.release();
        assertApproxEqAbs(tf.balanceOf(alice), 100_000 ether, 2);
        assertGt(rest, 45_000 ether);
    }
}
