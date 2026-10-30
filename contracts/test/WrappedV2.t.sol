// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TapeFoundryWrappedV2} from "../src/TapeFoundryWrappedV2.sol";

contract MockProcessor is ERC721 {
    mapping(uint256 => bytes) internal nls;
    mapping(uint256 => uint32) internal gs;

    constructor() ERC721("Circuit", "CIR") {}

    function mint(address to, uint256 id, bytes calldata nl, uint32 g) external {
        nls[id] = nl;
        gs[id] = g;
        _mint(to, id);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return nls[id];
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        return (2, 2, 0, gs[id]);
    }
}

contract MockRegistry {
    struct D {
        bytes32 hash;
        uint16 max;
        uint16 minted;
        bool live;
    }

    mapping(uint16 => mapping(uint8 => D)) public drawings;
    mapping(address => mapping(uint256 => uint16)) internal ed;

    function register(uint16 e, uint8 d, bytes32 h, uint16 m) external {
        drawings[e][d] = D(h, m, 0, true);
    }

    function setEdition(address cpu, uint256 id, uint16 n) external {
        ed[cpu][id] = n;
    }

    function editionOf(address cpu, uint256 id) external view returns (uint16, uint8, uint16) {
        return (1, 0, ed[cpu][id]);
    }
}

contract WrappedV2Test is Test {
    TapeFoundryWrappedV2 w;
    MockProcessor cpu;
    MockRegistry reg;

    address alice = address(0xA11CE);
    bytes NL = hex"00000002000002";   // 一个 NOT 门

    function setUp() public {
        w = new TapeFoundryWrappedV2(address(this));
        cpu = new MockProcessor();
        reg = new MockRegistry();

        w.setProcessor(address(cpu), true);
        w.setRegistry(address(reg));
        w.setLabel(0, "ADD4");

        reg.register(1, 0, keccak256(NL), 700);
        cpu.mint(alice, 7, NL, 46);
        reg.setEdition(address(cpu), 7, 12);
    }

    function test_wrap_ok() public {
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        uint256 id = w.wrap(1, 0, address(cpu), 7);
        vm.stopPrank();

        assertEq(id, 1);
        assertEq(w.ownerOf(1), alice);
        assertEq(cpu.ownerOf(7), address(w));

        (address c, uint32 cid, uint32 gates, uint16 edition, uint16 epoch, uint8 drawing) =
            w.original(1);
        assertEq(c, address(cpu));
        assertEq(cid, 7);
        assertEq(gates, 46);
        assertEq(edition, 12);
        assertEq(epoch, 1);
        assertEq(drawing, 0);
    }

    function test_wrap_rejects_wrong_drawing() public {
        reg.register(1, 1, keccak256("something else"), 100);
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        vm.expectRevert(TapeFoundryWrappedV2.HashMismatch.selector);
        w.wrap(1, 1, address(cpu), 7);
        vm.stopPrank();
    }

    function test_wrap_rejects_unknown_drawing() public {
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        vm.expectRevert(TapeFoundryWrappedV2.UnknownDrawing.selector);
        w.wrap(1, 9, address(cpu), 7);
        vm.stopPrank();
    }

    function test_wrap_twice_reverts() public {
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        w.wrap(1, 0, address(cpu), 7);
        vm.expectRevert(TapeFoundryWrappedV2.AlreadyWrapped.selector);
        w.wrap(1, 0, address(cpu), 7);
        vm.stopPrank();
    }

    function test_royalty_is_5_percent() public view {
        (address receiver, uint256 amount) = w.royaltyInfo(1, 1 ether);
        assertEq(receiver, address(this));
        assertEq(amount, 0.05 ether);
        assertTrue(w.supportsInterface(0x2a55205a));
    }

    function test_unwrap_returns_card() public {
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        w.wrap(1, 0, address(cpu), 7);
        w.unwrap(1);
        vm.stopPrank();

        assertEq(cpu.ownerOf(7), alice);
        assertEq(w.balanceOf(alice), 0);
    }

    function test_token_uri_has_metadata() public {
        vm.startPrank(alice);
        cpu.approve(address(w), 7);
        w.wrap(1, 0, address(cpu), 7);
        vm.stopPrank();

        string memory uri = w.tokenURI(1);
        assertTrue(bytes(uri).length > 100);
    }
}
