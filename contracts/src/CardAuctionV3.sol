// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title CardAuctionV3
/// @notice Auction + optional buy-now, priced in BEM, with a one-transaction sweep.
contract CardAuctionV3 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC721 public immutable cards;
    IERC20 public immutable bem;
    address public owner;
    address public treasury;

    uint16 public feeBps;
    uint16 public constant MAX_FEE_BPS = 500;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;
    uint64 public constant EXTENSION = 5 minutes;
    uint64 public constant EXTENSION_WINDOW = 5 minutes;
    uint16 public constant MIN_STEP_BPS = 500;

    struct Auction {
        address seller;
        uint96 reserve;
        uint96 highest;
        address highestBidder;
        uint64 endAt;
        uint96 buyNow;      // 0 = auction only
        bool settled;
        bool cancelled;
    }

    mapping(uint256 => Auction) public auctions;
    mapping(address => uint256) public credits;

    event Created(uint256 indexed tokenId, address indexed seller, uint96 reserve, uint96 buyNow, uint64 endAt);
    event Bid(uint256 indexed tokenId, address indexed bidder, uint96 amount, uint64 endAt);
    event Bought(uint256 indexed tokenId, address indexed buyer, uint96 amount, uint96 fee);
    event Settled(uint256 indexed tokenId, address indexed winner, uint96 amount, uint96 fee);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Withdrawn(address indexed who, uint256 amount);
    event FeeSet(uint16 feeBps);

    error NotOwner();
    error NotSeller();
    error BadDuration();
    error BadPrice();
    error AlreadyLive();
    error NotLive();
    error TooLow();
    error HasBids();
    error NoBids();
    error NotEnded();
    error NotForSale();
    error NothingToWithdraw();
    error EmptySweep();

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
        if (bps > MAX_FEE_BPS) revert BadPrice();
        feeBps = bps;
        emit FeeSet(bps);
    }

    function createAuction(uint256 tokenId, uint96 reserve, uint64 duration, uint96 buyNow) external nonReentrant {
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (reserve == 0) revert BadPrice();
        if (buyNow != 0 && buyNow < reserve) revert BadPrice();
        Auction storage a = auctions[tokenId];
        if (a.seller != address(0) && !a.settled && !a.cancelled) revert AlreadyLive();

        cards.transferFrom(msg.sender, address(this), tokenId);
        uint64 endAt = uint64(block.timestamp) + duration;
        auctions[tokenId] = Auction(msg.sender, reserve, 0, address(0), endAt, buyNow, false, false);
        emit Created(tokenId, msg.sender, reserve, buyNow, endAt);
    }

    function bid(uint256 tokenId, uint96 amount) external nonReentrant {
        Auction storage a = auctions[tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (block.timestamp >= a.endAt) revert NotEnded();
        if (amount < a.reserve) revert TooLow();
        if (a.highest != 0) {
            uint256 step = (uint256(a.highest) * MIN_STEP_BPS) / 10_000;
            if (step == 0) step = 1;
            if (amount < uint256(a.highest) + step) revert TooLow();
        }
        if (a.buyNow != 0 && amount >= a.buyNow) revert TooLow();

        bem.safeTransferFrom(msg.sender, address(this), amount);
        if (a.highestBidder != address(0)) credits[a.highestBidder] += a.highest;
        a.highest = amount;
        a.highestBidder = msg.sender;
        if (a.endAt - block.timestamp < EXTENSION_WINDOW) a.endAt = uint64(block.timestamp) + EXTENSION;
        emit Bid(tokenId, msg.sender, amount, a.endAt);
    }

    /// @notice Buy at the buy-now price. Buyer must have approved BEM first.
    function buy(uint256 tokenId) external nonReentrant {
        _buy(tokenId, msg.sender);
    }

    /// @notice Buy several cards at their buy-now prices in one transaction.
    function sweep(uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert EmptySweep();
        uint256 total;
        for (uint256 i; i < tokenIds.length; i++) {
            Auction storage a = auctions[tokenIds[i]];
            if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
            if (block.timestamp >= a.endAt) revert NotEnded();
            if (a.buyNow == 0) revert NotForSale();
            if (msg.sender == a.seller) revert NotSeller();
            for (uint256 j; j < i; j++) if (tokenIds[j] == tokenIds[i]) revert AlreadyLive();
            total += a.buyNow;
        }
        bem.safeTransferFrom(msg.sender, address(this), total);
        for (uint256 i; i < tokenIds.length; i++) _settleBuy(tokenIds[i], msg.sender);
    }

    function _buy(uint256 tokenId, address buyer) internal {
        Auction storage a = auctions[tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (block.timestamp >= a.endAt) revert NotEnded();
        if (a.buyNow == 0) revert NotForSale();
        if (buyer == a.seller) revert NotSeller();
        bem.safeTransferFrom(buyer, address(this), a.buyNow);
        _settleBuy(tokenId, buyer);
    }

    function _settleBuy(uint256 tokenId, address buyer) internal {
        Auction storage a = auctions[tokenId];
        a.settled = true;
        uint256 amount = a.buyNow;
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) bem.safeTransfer(treasury, fee);
        bem.safeTransfer(a.seller, amount - fee);
        cards.transferFrom(address(this), buyer, tokenId);
        emit Bought(tokenId, buyer, uint96(amount), uint96(fee));
    }

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

    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        bem.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
