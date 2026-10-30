// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC721} from "openzeppelin-contracts/contracts/token/ERC721/ERC721.sol";
import {TapeFoundryWrapped} from "../src/TapeFoundryWrapped.sol";

contract MockCircuit is ERC721 {
    mapping(uint256 => uint32) public gates;
    constructor() ERC721("Mock Circuit", "MC") {}
    function mint(address to, uint256 id, uint32 g) external {
        gates[id] = g;
        _mint(to, id);
    }
    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        return (1, 1, 0, gates[id]);
    }
    function exists(uint256 id) external view returns (bool) {
        return _ownerOf(id) != address(0);
    }
}

contract MockRegistry {
    function editionOf(address, uint256) external pure returns (uint16, uint8, uint16) {
        return (0, 12, 2);
    }
}

contract WrappedTest is Test {
    TapeFoundryWrapped w;
    MockCircuit cpu;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        w = new TapeFoundryWrapped(address(this));
        cpu = new MockCircuit();
        w.setProcessor(address(cpu), true);
        w.setLabel(12, "ADD4");

        cpu.mint(alice, 3, 52);
        vm.prank(alice);
        cpu.setApprovalForAll(address(w), true);
    }

    function testWrapHoldsOriginalAndMintsCopy() public {
        vm.prank(alice);
        uint256 id = w.wrap(address(cpu), 3);

        assertEq(id, 1);
        assertEq(w.ownerOf(1), alice);
        assertEq(cpu.ownerOf(3), address(w));          // 原卡被锁在合约里

        (address c, uint32 cid, uint32 gates, uint16 ed, uint8 draw) = w.original(1);
        assertEq(c, address(cpu));
        assertEq(cid, 3);
        assertEq(gates, 52);
        assertEq(ed, 0);                                // 还没有登记册
        assertEq(draw, 0);
    }

    function testTokenUriHasImageAndJson() public {
        vm.prank(alice);
        w.wrap(address(cpu), 3);
        string memory uri = w.tokenURI(1);
        bytes memory b = bytes(uri);
        assertGt(b.length, 400);
        // 前缀是 JSON data URI
        assertEq(_startsWith(uri, "data:application/json;base64,"), true);
    }

    function testReadsEditionFromRegistry() public {
        MockRegistry reg = new MockRegistry();
        w.setRegistry(address(reg));

        vm.prank(alice);
        w.wrap(address(cpu), 3);

        (,,, uint16 ed,) = w.original(1);
        assertEq(ed, 2);
        w.setMaxEdition(100);
        string memory uri = w.tokenURI(1);
        assertGt(bytes(uri).length, 400);
    }

    function testRefreshPicksUpLaterEdition() public {
        vm.prank(alice);
        w.wrap(address(cpu), 3);

        w.setRegistry(address(new MockRegistry()));
        w.refresh(1);

        (,,, uint16 ed, uint8 draw) = w.original(1);
        assertEq(ed, 2);
        assertEq(draw, 12);
    }

    function testRejectsForeignProcessor() public {
        MockCircuit other = new MockCircuit();
        other.mint(alice, 9, 10);
        vm.prank(alice);
        other.setApprovalForAll(address(w), true);

        vm.prank(alice);
        vm.expectRevert(TapeFoundryWrapped.NotProcessor.selector);
        w.wrap(address(other), 9);
    }

    function testRejectsNonHolder() public {
        vm.prank(bob);
        vm.expectRevert(TapeFoundryWrapped.NotHolder.selector);
        w.wrap(address(cpu), 3);
    }

    function testRejectsDoubleWrap() public {
        vm.startPrank(alice);
        w.wrap(address(cpu), 3);
        vm.expectRevert(TapeFoundryWrapped.AlreadyWrapped.selector);
        w.wrap(address(cpu), 3);
        vm.stopPrank();
    }

    function testUnwrapReturnsOriginal() public {
        vm.prank(alice);
        w.wrap(address(cpu), 3);

        vm.prank(alice);
        w.unwrap(1);

        assertEq(cpu.ownerOf(3), alice);
        vm.expectRevert();
        w.ownerOf(1);
        (address c,, , ,) = w.original(1);
        assertEq(c, address(0));
    }

    function testOnlyHolderCanUnwrap() public {
        vm.prank(alice);
        w.wrap(address(cpu), 3);

        vm.prank(bob);
        vm.expectRevert();
        w.unwrap(1);
    }

    function testWrapperIsTransferable() public {
        vm.prank(alice);
        w.wrap(address(cpu), 3);

        vm.prank(alice);
        w.transferFrom(alice, bob, 1);
        assertEq(w.ownerOf(1), bob);
        assertEq(cpu.ownerOf(3), address(w));   // 原卡仍锁着，跟着包装走
    }

    function _startsWith(string memory s, string memory p) internal pure returns (bool) {
        bytes memory a = bytes(s);
        bytes memory b = bytes(p);
        if (a.length < b.length) return false;
        for (uint256 i = 0; i < b.length; i++) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
