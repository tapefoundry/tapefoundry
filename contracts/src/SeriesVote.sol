// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOwnerOf {
    function ownerOf(uint256 id) external view returns (address);
}

interface IEditionOf {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
}

/// @title SeriesVote
/// @notice 一卡一票。卡片本身是选票：调用时校验持有 + 期号，投过的卡不能再投。
///         不托管、不托管私钥、不依赖链下快照。
contract SeriesVote {
    address public immutable processor;
    address public immutable registry;
    uint16 public immutable epoch;
    address public owner;

    string[] private _options;
    uint256[] private _tally;
    uint256 public totalVotes; // 已投票的卡片数
    bool public open;

    mapping(uint256 => bool) public voted; // circuitId => 已投

    event Voted(address indexed voter, uint8 indexed choice, uint256 cards);
    event OpenChanged(bool open);
    event OwnerChanged(address owner);

    error Closed();
    error BadChoice();
    error NotOwner();
    error WrongEpoch();
    error AlreadyVoted();
    error NoCards();
    error NotOwnerOfContract();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwnerOfContract();
        _;
    }

    constructor(address cpu, address reg, uint16 epoch_, string[] memory options_) {
        processor = cpu;
        registry = reg;
        epoch = epoch_;
        owner = msg.sender;
        for (uint256 i; i < options_.length; i++) {
            _options.push(options_[i]);
            _tally.push(0);
        }
    }

    function optionCount() external view returns (uint256) {
        return _options.length;
    }

    function option(uint256 i) external view returns (string memory) {
        return _options[i];
    }

    function tally(uint256 i) external view returns (uint256) {
        return _tally[i];
    }

    /// @notice 开始时由项目方打开；关闭后不再接受投票。
    function setOpen(bool v) external onlyOwner {
        open = v;
        emit OpenChanged(v);
    }

    function transferOwnership(address next) external onlyOwner {
        owner = next;
        emit OwnerChanged(next);
    }

    /// @notice 用自己持有的卡投票。ids 里每张卡算一票。
    function vote(uint8 choice, uint256[] calldata ids) external {
        if (!open) revert Closed();
        if (choice >= _options.length) revert BadChoice();
        uint256 n;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (voted[id]) revert AlreadyVoted();
            if (IOwnerOf(processor).ownerOf(id) != msg.sender) revert NotOwner();
            (uint16 e,,) = IEditionOf(registry).editionOf(processor, id);
            if (e != epoch) revert WrongEpoch();
            voted[id] = true;
            n++;
        }
        if (n == 0) revert NoCards();
        _tally[choice] += n;
        totalVotes += n;
        emit Voted(msg.sender, choice, n);
    }
}
