// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface IEditionRegistry {
    function editionOf(address cpu, uint256 circuitId)
        external
        view
        returns (uint16 epoch, uint8 drawing, uint16 number);
}

/// @title TapeFoundry Offer Book
/// @notice Buyer-side offers for one specific raw, numbered TapeFoundry card.
///         The buyer's BEM is escrowed; the current owner accepts and the card
///         and BEM change hands atomically. Existing auctions are untouched.
contract TapeFoundryOfferBook is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable bem;
    IERC721 public immutable cards;
    IEditionRegistry public immutable registry;
    address public immutable treasury;

    /// @notice 1% of the offer amount, paid to the same treasury as the market.
    uint16 public constant FEE_BPS = 100;
    uint64 public constant MIN_DURATION = 1 hours;
    uint64 public constant MAX_DURATION = 30 days;

    struct Offer {
        address buyer;
        uint96 amount;
        uint64 expiresAt;
        uint256 tokenId;
        bool active;
    }

    mapping(uint256 => Offer) public offers;
    /// @notice One active token-specific offer per buyer. Prevents accidental
    ///         duplicate escrows; the buyer cancels the old offer before a new one.
    mapping(address => mapping(uint256 => uint256)) public activeOfferOf;
    uint256 public nextOfferId = 1;

    event OfferCreated(
        uint256 indexed offerId,
        uint256 indexed tokenId,
        address indexed buyer,
        uint96 amount,
        uint64 expiresAt
    );
    event OfferCancelled(uint256 indexed offerId, address indexed buyer);
    event OfferAccepted(
        uint256 indexed offerId,
        uint256 indexed tokenId,
        address indexed buyer,
        address seller,
        uint96 amount,
        uint96 fee
    );

    error ZeroAmount();
    error BadExpiry();
    error NotNumbered();
    error OfferExists();
    error NotBuyer();
    error NotActive();
    error Expired();
    error NotOwner();
    error SelfTrade();

    constructor(address bem_, address cards_, address registry_, address treasury_) {
        bem = IERC20(bem_);
        cards = IERC721(cards_);
        registry = IEditionRegistry(registry_);
        treasury = treasury_;
    }

    /// @notice Escrow BEM for a specific numbered card. The card may currently
    ///         be unlisted, listed, staked or wrapped; acceptance checks ownership.
    function createOffer(uint256 tokenId, uint96 amount, uint64 expiresAt) external nonReentrant returns (uint256 offerId) {
        if (amount == 0) revert ZeroAmount();
        if (expiresAt <= block.timestamp || expiresAt > block.timestamp + MAX_DURATION) revert BadExpiry();
        (,, uint16 number) = registry.editionOf(address(cards), tokenId);
        if (number == 0) revert NotNumbered();
        if (activeOfferOf[msg.sender][tokenId] != 0) revert OfferExists();

        offerId = nextOfferId++;
        offers[offerId] = Offer({
            buyer: msg.sender,
            amount: amount,
            expiresAt: expiresAt,
            tokenId: tokenId,
            active: true
        });
        activeOfferOf[msg.sender][tokenId] = offerId;

        bem.safeTransferFrom(msg.sender, address(this), amount);
        emit OfferCreated(offerId, tokenId, msg.sender, amount, expiresAt);
    }

    /// @notice Buyer can cancel at any time, including after expiry, and get the
    ///         full escrowed amount back.
    function cancelOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (!o.active) revert NotActive();
        if (msg.sender != o.buyer) revert NotBuyer();

        o.active = false;
        delete activeOfferOf[o.buyer][o.tokenId];
        bem.safeTransfer(o.buyer, o.amount);
        emit OfferCancelled(offerId, o.buyer);
    }

    /// @notice Current owner accepts. If the card is in the auction market,
    ///         staking contract or wrapper, ownerOf is not the seller and this
    ///         reverts; the UI must tell the seller to remove it first.
    function acceptOffer(uint256 offerId) external nonReentrant {
        Offer storage o = offers[offerId];
        if (!o.active) revert NotActive();
        if (block.timestamp >= o.expiresAt) revert Expired();
        if (cards.ownerOf(o.tokenId) != msg.sender) revert NotOwner();
        if (msg.sender == o.buyer) revert SelfTrade();

        // Effects before interactions.
        o.active = false;
        delete activeOfferOf[o.buyer][o.tokenId];

        uint256 amount = o.amount;
        uint256 fee = (amount * FEE_BPS) / 10_000;
        uint256 sellerProceeds = amount - fee;
        if (fee > 0) bem.safeTransfer(treasury, fee);
        bem.safeTransfer(msg.sender, sellerProceeds);
        cards.safeTransferFrom(msg.sender, o.buyer, o.tokenId);

        emit OfferAccepted(offerId, o.tokenId, o.buyer, msg.sender, o.amount, uint96(fee));
    }

    function getOffer(uint256 offerId) external view returns (Offer memory) {
        return offers[offerId];
    }
}
