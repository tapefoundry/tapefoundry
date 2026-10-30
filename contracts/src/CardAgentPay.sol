// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title CardAgentPay
/// @notice One paid question to a card-bound agent. 70% to the card owner, 30% to the treasury.
contract CardAgentPay {
    IERC20 public immutable bem;
    IERC721 public immutable cards;
    address public immutable treasury;
    address public owner;
    uint256 public price; // in BEM units (8 decimals)

    event Asked(
        uint256 indexed tokenId,
        address indexed payer,
        address indexed cardOwner,
        uint256 amount,
        uint256 ownerCut
    );
    event PriceSet(uint256 price);

    constructor(address bem_, address cards_, address treasury_, uint256 price_) {
        require(bem_ != address(0) && cards_ != address(0) && treasury_ != address(0), "zero");
        bem = IERC20(bem_);
        cards = IERC721(cards_);
        treasury = treasury_;
        owner = msg.sender;
        price = price_;
    }

    function ask(uint256 tokenId) external {
        uint256 p = price;
        require(p > 0, "price");
        address cardOwner = cards.ownerOf(tokenId);
        uint256 ownerCut = (p * 70) / 100;
        require(bem.transferFrom(msg.sender, cardOwner, ownerCut), "owner pay");
        require(bem.transferFrom(msg.sender, treasury, p - ownerCut), "treasury pay");
        emit Asked(tokenId, msg.sender, cardOwner, p, ownerCut);
    }

    function setPrice(uint256 price_) external {
        require(msg.sender == owner, "owner");
        price = price_;
        emit PriceSet(price_);
    }
}
