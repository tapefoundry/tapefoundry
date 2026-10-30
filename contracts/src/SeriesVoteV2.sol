// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IProcessorV2 {
    function ownerOf(uint256 id) external view returns (address);
}

interface IEditionsV2 {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
}

interface IStakingV2 {
    // TFStakingSeason1V2.stakes(uint256) public mapping
    function stakes(uint256 id)
        external view returns (address owner, uint32 id_, uint32 gates, uint8 drawing, uint256 weight);
}

interface IWrapperV2 {
    function wrapperOf(address cpu, uint256 circuitId) external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title SeriesVoteV2
/// @notice One numbered Series 01 card = one vote. Unlike v1, a card still
///         staked in TFStakingSeason1V2 counts through its actual staker, and a
///         wrapped TFD counts through the TFD holder. No staking or mining state
///         is changed by voting.
/// @dev Votes are keyed by circuit id, not wallet. A card that has voted can
///      never vote again, even after transfer, unstake, re-stake, wrap or unwrap.
contract SeriesVoteV2 {
    address public immutable processor;
    address public immutable registry;
    address public immutable staking;
    address public immutable wrapper;
    uint16 public immutable epoch;

    address public owner;

    string[] private _options;
    uint256[] private _tally;
    uint256 public totalVotes; // number of cards that have voted
    bool public open;

    mapping(uint256 => bool) public voted; // circuitId => vote spent

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

    constructor(
        address cpu,
        address reg,
        address staking_,
        address wrapper_,
        uint16 epoch_,
        string[] memory options_
    ) {
        processor = cpu;
        registry = reg;
        staking = staking_;
        wrapper = wrapper_;
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

    function setOpen(bool v) external onlyOwner {
        open = v;
        emit OpenChanged(v);
    }

    function transferOwnership(address next) external onlyOwner {
        owner = next;
        emit OwnerChanged(next);
    }

    /// @notice Resolve the wallet that actually controls a card.
    ///         Direct owner -> staking position owner -> wrapped TFD owner.
    function _holderOf(uint256 id) internal view returns (address holder) {
        holder = IProcessorV2(processor).ownerOf(id);

        if (holder == staking && staking != address(0)) {
            (address staker,,, , ) = IStakingV2(staking).stakes(id);
            if (staker != address(0)) holder = staker;
        }

        if (holder == wrapper && wrapper != address(0)) {
            uint256 tfd = IWrapperV2(wrapper).wrapperOf(processor, id);
            if (tfd != 0) holder = IWrapperV2(wrapper).ownerOf(tfd);
        }
    }

    /// @notice Vote with any number of cards controlled by msg.sender.
    ///         A card can be used once, forever.
    function vote(uint8 choice, uint256[] calldata ids) external {
        if (!open) revert Closed();
        if (choice >= _options.length) revert BadChoice();

        uint256 n;
        for (uint256 i; i < ids.length; i++) {
            uint256 id = ids[i];
            if (voted[id]) revert AlreadyVoted();
            if (_holderOf(id) != msg.sender) revert NotOwner();
            (uint16 e,,) = IEditionsV2(registry).editionOf(processor, id);
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
