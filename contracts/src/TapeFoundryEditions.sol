// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TapeFoundry Editions
/// @notice 图纸公开，编号限量。TapeOut 协议本身没法给「同一张图纸只出 100 份」设上限
///         （零件总量下限 10,000，按门数算只能得到隐含上限），所以上限和编号放在这里。
///
///         规则只有一条：谁持有那张电路，谁才能领它的编号；领的时候把链上存的网表
///         重新哈希一遍，必须等于登记的图纸哈希。
///
///         合约不持有任何钱，也不发 NFT —— 它只是一本账。
interface IProcessor {
    function ownerOf(uint256 id) external view returns (address);
    function netlist(uint256 id) external view returns (bytes memory);
}

contract TapeFoundryEditions {
    struct Drawing {
        bytes32 hash;   // 图纸网表的 sha256
        uint16 max;     // 这一期最多几份
        uint16 minted;  // 已领
        bool live;
    }

    struct Edition {
        uint16 epoch;
        uint8 drawing;
        uint16 number;  // 0 = 未领
    }

    address public owner;
    mapping(address => bool) public processor;
    mapping(uint16 => mapping(uint8 => Drawing)) public drawings;
    mapping(address => mapping(uint256 => Edition)) public editions;

    event Registered(uint16 indexed epoch, uint8 indexed drawingId, bytes32 hash, uint16 max);
    event Claimed(
        uint16 indexed epoch, uint8 indexed drawingId, uint16 number,
        address indexed holder, address cpu, uint256 circuitId
    );
    event ProcessorSet(address indexed cpu, bool ok);
    event OwnerChanged(address indexed from, address indexed to);

    error NotOwner();
    error NotProcessor();
    error NotHolder();
    error NotDrawing();
    error HashMismatch();
    error SoldOut();
    error AlreadyClaimed();
    error ZeroMax();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnerChanged(address(0), msg.sender);
    }

    // ───────── 管理 ─────────
    function transferOwnership(address next) external onlyOwner {
        require(next != address(0), "zero owner");
        emit OwnerChanged(owner, next);
        owner = next;
    }

    function setProcessor(address cpu, bool ok) external onlyOwner {
        processor[cpu] = ok;
        emit ProcessorSet(cpu, ok);
    }

    /// @param epoch  期号。测试期 0，正式上线 1，互不占号。
    function register(uint16 epoch, uint8 drawingId, bytes32 hash, uint16 max)
        external onlyOwner
    {
        if (max == 0) revert ZeroMax();
        drawings[epoch][drawingId] = Drawing(hash, max, 0, true);
        emit Registered(epoch, drawingId, hash, max);
    }

    function close(uint16 epoch, uint8 drawingId) external onlyOwner {
        drawings[epoch][drawingId].live = false;
    }

    // ───────── 领编号 ─────────
    /// @notice 只能由电路的持有人调用。持有 = 现在 ownerOf 是你。
    function claim(uint16 epoch, uint8 drawingId, address cpu, uint256 circuitId)
        external returns (uint16 number)
    {
        Drawing storage d = drawings[epoch][drawingId];
        if (!d.live) revert NotDrawing();
        if (!processor[cpu]) revert NotProcessor();
        if (IProcessor(cpu).ownerOf(circuitId) != msg.sender) revert NotHolder();
        if (editions[cpu][circuitId].number != 0) revert AlreadyClaimed();
        if (keccak256(IProcessor(cpu).netlist(circuitId)) != d.hash) revert HashMismatch();
        if (d.minted >= d.max) revert SoldOut();

        unchecked { d.minted += 1; }
        number = d.minted;
        editions[cpu][circuitId] = Edition(epoch, drawingId, number);
        emit Claimed(epoch, drawingId, number, msg.sender, cpu, circuitId);
    }

    // ───────── 查询 ─────────
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number)
    {
        Edition memory e = editions[cpu][circuitId];
        return (e.epoch, e.drawing, e.number);
    }

    function remaining(uint16 epoch, uint8 drawingId) external view returns (uint16) {
        Drawing memory d = drawings[epoch][drawingId];
        return d.max > d.minted ? d.max - d.minted : 0;
    }

    function issued(uint16 epoch, uint8 drawingId) external view returns (uint16) {
        return drawings[epoch][drawingId].minted;
    }
}
