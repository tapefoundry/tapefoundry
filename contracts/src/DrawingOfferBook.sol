// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IDrawingRegistry {
    function editionOf(address cpu, uint256 circuitId)
        external
        view
        returns (uint16 epoch, uint8 drawing, uint16 number);
}

/// @title TapeFoundry Drawing Offer Book
/// @notice Buyer-side offers for ANY numbered card of one drawing (one of the
///         eleven Series 01 drawings). BEM is escrowed; the holder of any card
///         of that drawing accepts with the token they want to sell.
contract TapeFoundryDrawingOfferBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bem;
    IERC721 public immutable cards;
    IDrawingRegistry public immutable registry;
    address public immutable treasury;

    uint16 public constant FEE_BPS = 100;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;
    uint8 public constant DRAWING_COUNT = 11;

    struct Offer {
        address buyer;
        uint8 drawing;
        uint96 amount;
        uint64 expiresAt;
        bool active;
    }

    mapping(uint256 => Offer) public offers;
    /// @notice One active offer per buyer per drawing.
    mapping(address => mapping(uint8 => uint256)) public activeOfferOf;
    uint256 public nextOfferId = 1;

    event OfferCreated(
        uint256 indexed offerId,
        uint8 indexed drawing,
        address indexed buyer,
        uint96 amount,
        uint64 expiresAt
    );
    event OfferCancelled(uint256 indexed offerId, address indexed buyer);
    event OfferAccepted(
        uint256 indexed offerId,
        uint8 indexed drawing,
        uint256 indexed tokenId,
        address buyer,
        address seller,
        uint96 amount,
        uint96 fee
    );

    error ZeroAmount();
    error BadExpiry();
    error BadDrawing();
    error OfferExists();
    error NotBuyer();
    error NotActive();
    error Expired();
    error NotOwner();
    error SelfTrade();
    error NotNumbered();
    error WrongDrawing();

    constructor(address bem_, address cards_, address registry_, address treasury_) {
        bem = IERC20(bem_);
        cards = IERC721(cards_);
        registry = IDrawingRegistry(registry_);
        treasury = treasury_;
    }

    /// @notice Escrow BEM for any numbered card of `drawing`.
    function createOffer(uint8 drawing, uint96 amount, uint64 expiresAt) external nonReentrant returns (uint256 offerId) {
        if (drawing >= DRAWING_COUNT) revert BadDrawing();
        if (amount == 0) revert ZeroAmount();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_DURATION) revert BadExpiry();
        if (activeOfferOf[msg.sender][drawing] != 0) revert OfferExists();

        offerId = nextOfferId++;
        offers[offerId] = Offer({
            buyer: msg.sender,
            drawing: drawing,
            amount: amount,
            expiresAt: expiresAt,
            active: true
        });
        activeOfferOf[msg.sender][drawing] = offerId;

        bem.safeTransferFrom(msg.sender, address(this), amount);
        emit OfferCreated(offerId, drawing, msg.sender, amount, expiresAt);
    }

    /// @notice Buyer can cancel at any time, including after expiry, and get the
    ///         full escrowed amount back.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (!o.active) revert NotActive();
        if (msg.sender != o.buyer) revert NotBuyer();

        o.active = false;
        delete activeOfferOf[o.buyer][o.drawing];
        bem.safeTransfer(o.buyer, o.amount);
        emit OfferCancelled(offerId, o.buyer);
    }

    /// @notice A holder accepts with a specific numbered token of the offered
    ///         drawing. The chosen token is the seller's choice.
    function acceptOffer(uint256 offerId, uint256 tokenId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (!o.active) revert NotActive();
        if (block.timestamp >= o.expiresAt) revert Expired();
        if (cards.ownerOf(tokenId) != msg.sender) revert NotOwner();
        if (msg.sender == o.buyer) revert SelfTrade();

        (, uint8 drawingId, uint16 number) = registry.editionOf(address(cards), tokenId);
        if (number == 0) revert NotNumbered();
        if (drawingId != o.drawing) revert WrongDrawing();

        o.active = false;
        delete activeOfferOf[o.buyer][o.drawing];

        uint256 amount = o.amount;
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sellerProceeds = amount - fee;
        if (fee > 0) bem.safeTransfer(treasury, fee);
        bem.safeTransfer(msg.sender, sellerProceeds);
        cards.safeTransferFrom(msg.sender, o.buyer, tokenId);

        emit OfferAccepted(offerId, o.drawing, tokenId, o.buyer, msg.sender, o.amount, uint96(fee));
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }
}
