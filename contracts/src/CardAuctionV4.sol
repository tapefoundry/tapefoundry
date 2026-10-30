// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title CardAuctionV4
/// @notice Multi-collection marketplace. BEM priced. Auction + buy-now + sweep.
///         Collections are whitelisted by the owner and can carry a royalty.
contract CardAuctionV4 is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bem;
    address public owner;
    address public treasury;

    uint16 public constant MAX_FEE_BPS = 500;
    uint16 public constant MAX_ROYALTY_BPS = 1000;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;
    uint64 public constant EXTENSION = 5 minutes;
    uint64 public constant EXTENSION_WINDOW = 5 minutes;
    uint16 public constant MIN_STEP_BPS = 500;

    struct Collection {
        bool allowed;
        uint16 feeBps;
        uint96 royaltyBps;
        address royaltyReceiver;
    }

    struct Auction {
        address seller;
        uint96 reserve;
        uint96 highest;
        address highestBidder;
        uint64 endAt;
        uint96 buyNow;
        bool settled;
        bool cancelled;
    }

    mapping(address => Collection) public collections;
    mapping(address => mapping(uint256 => Auction)) public auctions;
    mapping(address => uint256) public credits;

    event CollectionSet(address indexed collection, bool allowed, uint16 feeBps, uint96 royaltyBps, address royaltyReceiver);
    event Created(address indexed collection, uint256 indexed tokenId, address indexed seller, uint96 reserve, uint96 buyNow, uint64 endAt);
    event Bid(address indexed collection, uint256 indexed tokenId, address indexed bidder, uint96 amount, uint64 endAt);
    event Bought(address indexed collection, uint256 indexed tokenId, address indexed buyer, uint96 amount, uint96 fee);
    event Settled(address indexed collection, uint256 indexed tokenId, address indexed winner, uint96 amount, uint96 fee);
    event Cancelled(address indexed collection, uint256 indexed tokenId, address indexed seller);
    event Withdrawn(address indexed who, uint256 amount);

    error NotOwner();
    error NotAllowed();
    error NotSeller();
    error BadDuration();
    error BadPrice();
    error BadConfig();
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

    constructor(address bem_, address treasury_) {
        bem = IERC20(bem_);
        treasury = treasury_;
        owner = msg.sender;
    }

    function addCollection(address collection, uint16 feeBps, uint96 royaltyBps, address royaltyReceiver) external onlyOwner {
        if (feeBps > MAX_FEE_BPS || royaltyBps > MAX_ROYALTY_BPS) revert BadConfig();
        if (royaltyBps > 0 && royaltyReceiver == address(0)) revert BadConfig();
        collections[collection] = Collection(true, feeBps, royaltyBps, royaltyReceiver);
        emit CollectionSet(collection, true, feeBps, royaltyBps, royaltyReceiver);
    }

    function removeCollection(address collection) external onlyOwner {
        collections[collection].allowed = false;
        emit CollectionSet(collection, false, 0, 0, address(0));
    }

    function createAuction(address collection, uint256 tokenId, uint96 reserve, uint64 duration, uint96 buyNow) external nonReentrant {
        if (!collections[collection].allowed) revert NotAllowed();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (reserve == 0) revert BadPrice();
        if (buyNow != 0 && buyNow < reserve) revert BadPrice();
        Auction storage a = auctions[collection][tokenId];
        if (a.seller != address(0) && !a.settled && !a.cancelled) revert AlreadyLive();

        IERC721(collection).transferFrom(msg.sender, address(this), tokenId);
        uint64 endAt = uint64(block.timestamp) + duration;
        auctions[collection][tokenId] = Auction(msg.sender, reserve, 0, address(0), endAt, buyNow, false, false);
        emit Created(collection, tokenId, msg.sender, reserve, buyNow, endAt);
    }

    function bid(address collection, uint256 tokenId, uint96 amount) external nonReentrant {
        Auction storage a = auctions[collection][tokenId];
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
        emit Bid(collection, tokenId, msg.sender, amount, a.endAt);
    }

    function buy(address collection, uint256 tokenId) external nonReentrant {
        _buy(collection, tokenId, msg.sender);
    }

    function sweep(address collection, uint256[] calldata tokenIds) external nonReentrant {
        if (tokenIds.length == 0) revert EmptySweep();
        uint256 total;
        for (uint256 i; i < tokenIds.length; i++) {
            Auction storage a = auctions[collection][tokenIds[i]];
            if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
            if (block.timestamp >= a.endAt) revert NotEnded();
            if (a.buyNow == 0) revert NotForSale();
            if (msg.sender == a.seller) revert NotSeller();
            for (uint256 j; j < i; j++) if (tokenIds[j] == tokenIds[i]) revert AlreadyLive();
            total += a.buyNow;
        }
        bem.safeTransferFrom(msg.sender, address(this), total);
        for (uint256 i; i < tokenIds.length; i++) _settleBuy(collection, tokenIds[i], msg.sender);
    }

    function _buy(address collection, uint256 tokenId, address buyer) internal {
        Auction storage a = auctions[collection][tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (block.timestamp >= a.endAt) revert NotEnded();
        if (a.buyNow == 0) revert NotForSale();
        if (buyer == a.seller) revert NotSeller();
        bem.safeTransferFrom(buyer, address(this), a.buyNow);
        _settleBuy(collection, tokenId, buyer);
    }

    function _settleBuy(address collection, uint256 tokenId, address buyer) internal {
        Auction storage a = auctions[collection][tokenId];
        a.settled = true;
        uint256 amount = a.buyNow;
        uint256 fee = _payout(collection, a.seller, amount);
        IERC721(collection).transferFrom(address(this), buyer, tokenId);
        emit Bought(collection, tokenId, buyer, uint96(amount), uint96(fee));
    }

    function settle(address collection, uint256 tokenId) external nonReentrant {
        Auction storage a = auctions[collection][tokenId];
        if (a.seller == address(0) || a.settled || a.cancelled) revert NotLive();
        if (block.timestamp < a.endAt) revert NotEnded();
        if (a.highestBidder == address(0)) revert NoBids();

        a.settled = true;
        uint256 amount = a.highest;
        uint256 fee = _payout(collection, a.seller, amount);
        IERC721(collection).transferFrom(address(this), a.highestBidder, tokenId);
        emit Settled(collection, tokenId, a.highestBidder, uint96(amount), uint96(fee));
    }

    function cancel(address collection, uint256 tokenId) external nonReentrant {
        Auction storage a = auctions[collection][tokenId];
        if (a.seller != msg.sender) revert NotSeller();
        if (a.settled || a.cancelled) revert NotLive();
        if (a.highestBidder != address(0)) {
            if (block.timestamp < a.endAt) revert HasBids();
            revert NoBids();
        }
        a.cancelled = true;
        IERC721(collection).transferFrom(address(this), a.seller, tokenId);
        emit Cancelled(collection, tokenId, a.seller);
    }

    function _payout(address collection, address seller, uint256 amount) internal returns (uint256 fee) {
        Collection memory c = collections[collection];
        fee = (amount * c.feeBps) / 10_000;
        uint256 royalty = c.royaltyBps > 0 ? (amount * c.royaltyBps) / 10_000 : 0;
        if (fee > 0) bem.safeTransfer(treasury, fee);
        if (royalty > 0) bem.safeTransfer(c.royaltyReceiver, royalty);
        bem.safeTransfer(seller, amount - fee - royalty);
    }

    function withdraw() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        credits[msg.sender] = 0;
        bem.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }
}
