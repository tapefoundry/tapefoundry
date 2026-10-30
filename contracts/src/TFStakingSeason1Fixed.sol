// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";

interface ICircuits {
    function ownerOf(uint256 id) external view returns (address);
    function circuitInfo(uint256 id)
        external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gates);
}

interface IEditions {
    function editionOf(address cpu, uint256 circuitId)
        external view returns (uint16 epoch, uint8 drawingId, uint16 number);
}

/// @title TapeFoundry Season 1 staking
/// @notice Stake at least 3 original circuit cards in one wallet. Rewards accrue
///         per second for exactly the time each weight is staked. Unstake and
///         claim at any time; no lock, no daily root, no claim deadline.
///         11 distinct drawings add +50 weight while all eleven are staked.
contract TFStakingSeason1Fixed is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable tf;
    IERC721 public immutable cards;
    address public immutable processor;
    address public immutable registry;
    uint64 public immutable start;

    uint256 public constant TOTAL = 270_000 ether;
    uint8 public constant DAYS = 15;
    uint256 public constant CARD_SCALE = 1e9;
    uint256 public constant SET_BONUS = 50e9;
    uint256 public constant MIN_CARDS = 3;
    uint256 public constant ACC_SCALE = 1e18;

    struct Stake {
        address owner;
        uint32 id;
        uint32 gates;
        uint8 drawing;
        uint256 weight;
    }

    mapping(uint256 => Stake) public stakes;
    mapping(address => uint256[]) public stakedIds;
    mapping(address => mapping(uint256 => uint256)) public stakeIndex; // 1-based
    mapping(address => uint256) public weightOf;
    mapping(address => uint256) public pending;
    mapping(address => uint256) public rewardDebt;
    mapping(address => mapping(uint8 => uint16)) public drawingCount;
    mapping(address => uint8) public distinctDrawings;
    mapping(address => bool) public excluded;

    uint256 public totalWeight;
    uint256 public accPerWeight; // 1e18 scale
    uint256 public lastUpdate;

    event Staked(address indexed user, uint256 indexed id, uint32 gates, uint8 drawing, uint256 weight);
    event Unstaked(address indexed user, uint256 indexed id, uint256 weight);
    event Claimed(address indexed user, uint256 amount);

    constructor(
        IERC20 _tf,
        IERC721 _cards,
        address _processor,
        address _registry,
        uint64 _start,
        address[] memory excluded_
    ) {
        require(address(_tf) != address(0), "tf zero");
        require(address(_cards) != address(0), "cards zero");
        require(_processor != address(0), "processor zero");
        require(_registry != address(0), "registry zero");
        require(_start > block.timestamp, "start in past");
        tf = _tf;
        cards = _cards;
        processor = _processor;
        registry = _registry;
        start = _start;
        lastUpdate = _start;
        for (uint256 i = 0; i < excluded_.length; i++) {
            excluded[excluded_[i]] = true;
        }
    }

    function dayPool(uint8 d) public pure returns (uint256) {
        require(d >= 1 && d <= DAYS, "bad day");
        return (TOTAL * (16 - uint256(d))) / 120;
    }

    function seasonEnd() public view returns (uint256) {
        return uint256(start) + 15 days;
    }

    function stakedCount(address user) external view returns (uint256) {
        return stakedIds[user].length;
    }

    function stakedIdAt(address user, uint256 i) external view returns (uint256) {
        return stakedIds[user][i];
    }

    /// @notice Claimable right now, including the seconds since the last update.
    function pendingOf(address user) public view returns (uint256) {
        uint256 acc = accPerWeight + _accruedSince(lastUpdate, block.timestamp);
        return pending[user] + (weightOf[user] * acc) / ACC_SCALE - rewardDebt[user];
    }

    function stake(uint256 id) external nonReentrant {
        _stakePrepare(msg.sender);
        uint256 oldWeight = weightOf[msg.sender];
        _stakeOne(msg.sender, id);
        _stakeFinish(msg.sender, oldWeight);
    }

    /// @notice Install up to 50 cards in one transaction. One approval covers all.
    function stakeMany(uint256[] calldata ids) external nonReentrant {
        require(ids.length > 0, "empty batch");
        require(ids.length <= 50, "batch too large");
        _stakePrepare(msg.sender);
        uint256 oldWeight = weightOf[msg.sender];
        for (uint256 i = 0; i < ids.length; i++) {
            _stakeOne(msg.sender, ids[i]);
        }
        _stakeFinish(msg.sender, oldWeight);
    }

    function unstake(uint256 id) external nonReentrant {
        _unstakePrepare(msg.sender);
        uint256 oldWeight = weightOf[msg.sender];
        _unstakeOne(msg.sender, id);
        _unstakeFinish(msg.sender, oldWeight);
    }

    /// @notice Remove up to 50 cards in one transaction.
    function unstakeMany(uint256[] calldata ids) external nonReentrant {
        require(ids.length > 0, "empty batch");
        require(ids.length <= 50, "batch too large");
        _unstakePrepare(msg.sender);
        uint256 oldWeight = weightOf[msg.sender];
        for (uint256 i = 0; i < ids.length; i++) {
            _unstakeOne(msg.sender, ids[i]);
        }
        _unstakeFinish(msg.sender, oldWeight);
    }

    function _stakePrepare(address user) internal {
        require(!excluded[user], "excluded");
        _update();
        _harvest(user);
    }

    function _stakeOne(address user, uint256 id) internal {
        require(stakes[id].owner == address(0), "already staked");
        require(cards.ownerOf(id) == user, "not owner");

        (uint32 gates, uint8 drawing) = _info(id);
        cards.transferFrom(user, address(this), id);

        uint256 w = Math.sqrt(uint256(gates) * 1e18);
        stakes[id] = Stake(user, uint32(id), gates, drawing, w);
        stakedIds[user].push(id);
        stakeIndex[user][id] = stakedIds[user].length;

        if (drawing != 255) {
            uint16 c = drawingCount[user][drawing];
            drawingCount[user][drawing] = c + 1;
            if (c == 0) distinctDrawings[user] += 1;
        }

        emit Staked(user, id, gates, drawing, w);
    }

    function _stakeFinish(address user, uint256 oldWeight) internal {
        uint256 newWeight = _weight(user);
        totalWeight = totalWeight - oldWeight + newWeight;
        weightOf[user] = newWeight;
        rewardDebt[user] = (newWeight * accPerWeight) / ACC_SCALE;
    }

    function _unstakePrepare(address user) internal {
        _update();
        _harvest(user);
    }

    function _unstakeOne(address user, uint256 id) internal {
        Stake memory s = stakes[id];
        require(s.owner == user, "not staker");

        _removeId(user, id);
        if (s.drawing != 255) {
            uint16 c = drawingCount[user][s.drawing];
            require(c > 0, "drawing underflow");
            drawingCount[user][s.drawing] = c - 1;
            if (c == 1) distinctDrawings[user] -= 1;
        }
        delete stakes[id];

        cards.transferFrom(address(this), user, id);
        emit Unstaked(user, id, s.weight);
    }

    function _unstakeFinish(address user, uint256 oldWeight) internal {
        uint256 newWeight = _weight(user);
        totalWeight = totalWeight - oldWeight + newWeight;
        weightOf[user] = newWeight;
        rewardDebt[user] = (newWeight * accPerWeight) / ACC_SCALE;
    }

    function claim() external nonReentrant {
        _update();
        _harvest(msg.sender);
        uint256 amount = pending[msg.sender];
        require(amount > 0, "nothing to claim");
        pending[msg.sender] = 0;
        tf.safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, amount);
    }

    function _info(uint256 id) internal view returns (uint32 gates, uint8 drawing) {
        (,,, gates) = ICircuits(processor).circuitInfo(id);
        require(gates > 0, "no gates");
        try IEditions(registry).editionOf(processor, id) returns
            (uint16, uint8 d, uint16)
        {
            drawing = d;
        } catch {
            // 255 = unregistered / no edition, not "drawing 0".
            drawing = 255;
        }
    }

    function _weight(address user) internal view returns (uint256) {
        uint256 n = stakedIds[user].length;
        if (n < MIN_CARDS) return 0;
        uint256 w;
        for (uint256 i = 0; i < n; i++) {
            w += stakes[stakedIds[user][i]].weight;
        }
        if (distinctDrawings[user] >= 11) w += SET_BONUS;
        return w;
    }

    function _removeId(address user, uint256 id) internal {
        uint256 idx = stakeIndex[user][id];
        require(idx > 0, "bad index");
        uint256 last = stakedIds[user].length;
        if (idx != last) {
            uint256 moved = stakedIds[user][last - 1];
            stakedIds[user][idx - 1] = moved;
            stakeIndex[user][moved] = idx;
        }
        stakedIds[user].pop();
        delete stakeIndex[user][id];
    }

    function _harvest(address user) internal {
        uint256 acc = accPerWeight;
        uint256 w = weightOf[user];
        if (w != 0) {
            pending[user] += (w * acc) / ACC_SCALE - rewardDebt[user];
        }
        rewardDebt[user] = (w * acc) / ACC_SCALE;
    }

    function _update() internal {
        uint256 nowTs = block.timestamp;
        if (lastUpdate >= nowTs) return;
        uint256 end = seasonEnd();
        if (lastUpdate >= end) return;
        uint256 t = lastUpdate;
        uint256 stopAt = nowTs < end ? nowTs : end;
        while (t < stopAt) {
            uint256 day = ((t - uint256(start)) / 1 days) + 1;
            uint256 dayEnd = uint256(start) + day * 1 days;
            uint256 stop = stopAt < dayEnd ? stopAt : dayEnd;
            uint256 dt = stop - t;
            if (totalWeight != 0) {
                uint256 pool = dayPool(uint8(day));
                accPerWeight += (pool * ACC_SCALE * dt) / (1 days * totalWeight);
            }
            t = stop;
        }
        lastUpdate = stopAt;
    }

    function _accruedSince(uint256 from, uint256 to) internal view returns (uint256 add) {
        if (from >= to || from >= seasonEnd()) return 0;
        uint256 stopAt = to < seasonEnd() ? to : seasonEnd();
        uint256 t = from < start ? start : from;
        while (t < stopAt) {
            uint256 day = ((t - uint256(start)) / 1 days) + 1;
            uint256 dayEnd = uint256(start) + day * 1 days;
            uint256 stop = stopAt < dayEnd ? stopAt : dayEnd;
            uint256 dt = stop - t;
            if (totalWeight != 0) {
                add += (dayPool(uint8(day)) * ACC_SCALE * dt) / (1 days * totalWeight);
            }
            t = stop;
        }
    }
}
