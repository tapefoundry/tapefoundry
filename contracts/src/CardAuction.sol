// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title CardAuction
/// @notice English auction for TapeFoundry circuit cards, priced in BEM.
///         The card is escrowed on create; bids are escrowed in BEM; the highest
///         bid at the end wins. Outbid BEM is credited and withdrawn by the bidder.
contract CardAuction is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC721 public immutable cards;
    IERC20 public immutable bem;
    address public owner;
    address public treasury;

    uint16 public feeBps; // 0 by default; hard cap 5%
    uint16 public constant MAX_FEE_BPS = 500;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;
    uint64 public constant EXTENSION = 5 minutes;
    uint64 public constant EXTENSION_WINDOW = 5 minutes;
    uint16 public constant MIN_STEP_BPS = 500; // 5% over the current highest bid

    struct Auction {
        address seller;
        uint96 reserve;
        uint96 highest;
        address highestBidder;
        uint64 endAt;
        bool settled;
        bool cancelled;
    }

    mapping(uint256 => Auction) public auctions;
    mapping(address => uint256) public credits;

    event Created(uint256 indexed tokenId, address indexed seller, uint96 reserve, uint64 endAt);
    event Bid(uint256 indexed tokenId, address indexed bidder, uint96 amount, uint64 endAt);
    event Settled(uint256 indexed tokenId, address indexed winner, uint96 amount, uint96 fee);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Withdrawn(address indexed who, uint256 amount);
    event FeeSet(uint16 feeBps);
    event TreasurySet(address treasury);

    error NotOwner();
    error NotSeller();
    error SellerCannotBid();
    error BadDuration();
    error BadReserve();
    error AlreadyLive();
    error NotLive();
    error TooLow();
    error HasBids();
    error NoBids();
    error NotEnded();
    error NothingToWithdraw();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address cards_, address bem_, address treasury_) {
        cards = IERC721(cards_);
        bem = IERC20(bem_);
        treasury = treasury_;
        owner = msg.sender;
    }

    function setFee(uint16 bps) external onlyOwner {
        if (bps > MAX_FEE_BPS) revert BadReserve();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function setTreasury(address t) external onlyOwner {
        treasury = t;
        emit TreasurySet(t);
    }

    /// @notice Escrow a card and open an auction. Caller must have approved this contract.
    function createAuction(uint256 tokenId, uint96 reserve, uint64 duration) external nonReentrant {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (reserve == 0) revert BadReserve();
        Auction storage a = auctions[tokenId];
        if (a.seller != address(0) && !a.settled && !a.cancelled) revert AlreadyLive();

        cards.transferFrom(msg.sender, address(this), tokenId);

        auctions[tokenId] = Auction({
            seller: msg.sender,
            reserve: reserve,
            highest: 0,
            highestBidder: address(0),
            endAt: uint64(block.timestamp) + duration,
            settled: false,
            cancelled: false
        });
        emit Created(tokenId, msg.sender, reserve, uint64(block.timestamp) + duration);
    }

    /// @notice Place a bid in BEM. The previous highest bidder is credited for withdrawal.
    function bid(uint256 tokenId, uint96 amount) external nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (msg.sender == a.seller) revert SellerCannotBid();
        if (block.timestamp >= a.endAt) revert NotEnded();
        if (amount < a.reserve) revert TooLow();
        if (a.highest != 0) {
            uint256 step = (uint256(a.highest) * MIN_STEP_BPS) / 10_000;
            if (step == 0) step = 1;
            if (amount < uint256(a.highest) + step) revert TooLow();
        }

        bem.safeTransferFrom(msg.sender, address(this), amount);

        if (a.highestBidder != address(0)) {
            credits[a.highestBidder] += a.highest;
        }
        a.highest = amount;
        a.highestBidder = msg.sender;

        if (a.endAt - block.timestamp < EXTENSION_WINDOW) {
            a.endAt = uint64(block.timestamp) + EXTENSION;
        }
        emit Bid(tokenId, msg.sender, amount, a.endAt);
    }

    /// @notice Settle after the end. Anyone can call; the winner pays nothing extra.
    function settle(uint256 tokenId) external nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (block.timestamp < a.endAt) revert NotEnded();
        if (a.highestBidder == address(0)) revert NoBids();

        a.settled = true;
        uint256 amount = a.highest;
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) bem.safeTransfer(treasury, fee);
        bem.safeTransfer(a.seller, amount - fee);
        cards.transferFrom(address(this), a.highestBidder, tokenId);
        emit Settled(tokenId, a.highestBidder, a.highest, uint96(fee));
    }

    /// @notice Seller reclaims the card: any time before the first bid, or after the end with no bids.
    function cancel(uint256 tokenId) external nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.seller != msg.sender) revert NotSeller();
        if (a.settled || a.cancelled) revert NotLive();
        if (a.highestBidder != address(0)) {
            if (block.timestamp < a.endAt) revert HasBids();
            revert NoBids();
        }
        a.cancelled = true;
        cards.transferFrom(address(this), a.seller, tokenId);
        emit Cancelled(tokenId, a.seller);
    }

    /// @notice Withdraw BEM credited from outbid bids.
    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        bem.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
