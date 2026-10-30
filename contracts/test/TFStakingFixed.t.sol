// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TapeFoundryToken} from "../src/TapeFoundryToken.sol";
import {TFStakingSeason1Fixed} from "../src/TFStakingSeason1Fixed.sol";

contract FixedMockCard is ERC721 {
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

contract FixedMockRegistry {
    mapping(uint256 => uint8) public drawing;
    function setDrawing(uint256 id, uint8 d) external { drawing[id] = d; }
    function editionOf(address, uint256 id) external view returns (uint16, uint8, uint16) {
        return (0, drawing[id], 0);
    }
}

contract TFStakingFixedTest is Test {
    TapeFoundryToken tf;
    FixedMockCard card;
    FixedMockRegistry reg;
    TFStakingSeason1Fixed staking;
    uint64 start;
    address alice = address(0xA11CE);

    function setUp() public {
        tf = new TapeFoundryToken(address(this), address(this));
        card = new FixedMockCard();
        reg = new FixedMockRegistry();
        start = uint64(block.timestamp + 1 days);
        address[] memory ex = new address[](0);
        staking = new TFStakingSeason1Fixed(tf, card, address(card), address(reg), start, ex);
        tf.transfer(address(staking), 270_000 ether);
    }

    function testDrawingZeroCountsForSet() public {
        // Real Series 01 drawing ids are 0..10; MUL12 is id 0.
        for (uint256 i = 1; i <= 11; i++) {
            reg.setDrawing(i, uint8(i - 1));
            card.mint(alice, i, 100);
            vm.prank(alice);
            card.approve(address(staking), i);
        }
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 11; i++) staking.stake(i);
        assertEq(staking.distinctDrawings(alice), 11);
        // 11 * sqrt(100)*1e9 = 110e9 + 50e9 set bonus.
        assertEq(staking.weightOf(alice), 160e9);
        vm.stopPrank();
    }

    function testUnstakeDrawingZeroKeepsCount() public {
        for (uint256 i = 1; i <= 11; i++) {
            reg.setDrawing(i, uint8(i - 1));
            card.mint(alice, i, 100);
            vm.prank(alice);
            card.approve(address(staking), i);
        }
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 11; i++) staking.stake(i);
        staking.unstake(1); // MUL12 / drawing 0
        assertEq(staking.distinctDrawings(alice), 10);
        assertEq(staking.weightOf(alice), 100e9);
        vm.stopPrank();
    }
}
