// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";

/// @title TapeFoundry Season 1 mining
/// @notice 270,000 TF over 15 days. Each day has a Merkle root of
///         (wallet, weight). Weights are computed off-chain from card ownership:
///         sqrt(gates) per card, +50 for a complete 11-drawing set, with a
///         12% per-wallet cap and redistribution. Claims are open-ended.
contract TFMiningSeason1 {
    using SafeERC20 for IERC20;

    IERC20 public immutable token;
    uint64 public immutable start;
    address public publisher;

    uint8 public constant DAYS = 15;
    uint256 public constant TOTAL = 270_000 ether;

    struct DayInfo {
        bytes32 root;
        uint256 totalWeight;
        uint256 pool;
        bool published;
    }

    mapping(uint8 => DayInfo) public dayInfo;
    mapping(uint8 => mapping(address => bool)) public claimed;

    event DayPublished(uint8 indexed d, bytes32 root, uint256 totalWeight, uint256 pool);
    event Claimed(uint8 indexed d, address indexed account, uint256 amount);

    constructor(IERC20 _token, uint64 _start, address _publisher) {
        require(address(_token) != address(0), "token zero");
        require(_start > block.timestamp, "start in past");
        require(_publisher != address(0), "publisher zero");
        token = _token;
        start = _start;
        publisher = _publisher;
    }

    modifier onlyPublisher() {
        require(msg.sender == publisher, "not publisher");
        _;
    }

    /// @notice Exact pool for day d (1..15), in TF wei.
    function dayPool(uint8 d) public pure returns (uint256) {
        require(d >= 1 && d <= DAYS, "bad day");
        return (TOTAL * (16 - uint256(d))) / 120;
    }

    /// @notice Publish the snapshot root for a day. Day 1 can be published at
    ///         the season start; day d at start + (d-1) days. Root is immutable.
    function publishDay(uint8 d, bytes32 root, uint256 totalWeight)
        external
        onlyPublisher
    {
        require(d >= 1 && d <= DAYS, "bad day");
        require(!dayInfo[d].published, "already published");
        require(root != bytes32(0), "root zero");
        require(totalWeight > 0, "weight zero");
        require(
            block.timestamp >= start + (uint256(d) - 1) * 1 days,
            "too early"
        );

        uint256 pool = dayPool(d);
        dayInfo[d] = DayInfo({
            root: root,
            totalWeight: totalWeight,
            pool: pool,
            published: true
        });
        emit DayPublished(d, root, totalWeight, pool);
    }

    /// @notice Claim one day's reward. Weight and proof come from the published
    ///         snapshot. Anyone can call; tokens go to msg.sender.
    function claim(uint8 d, uint256 weight, bytes32[] calldata proof) external {
        DayInfo memory info = dayInfo[d];
        require(info.published, "not published");
        require(!claimed[d][msg.sender], "already claimed");
        require(weight > 0 && weight <= info.totalWeight, "bad weight");

        // The off-chain weights are already capped at 12%. This check makes a
        // malformed root visible instead of silently paying an over-cap share.
        require(weight <= (info.totalWeight * 1200) / 10_000, "over cap");

        bytes32 leaf = keccak256(abi.encodePacked(d, msg.sender, weight));
        require(MerkleProof.verify(proof, info.root, leaf), "bad proof");

        uint256 amount = (info.pool * weight) / info.totalWeight;
        require(amount > 0, "zero amount");

        claimed[d][msg.sender] = true;
        token.safeTransfer(msg.sender, amount);
        emit Claimed(d, msg.sender, amount);
    }

    function seasonEnd() external view returns (uint256) {
        return uint256(start) + 15 days;
    }
}
