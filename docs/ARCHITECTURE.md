# Architecture

TapeFoundry is a set of small, non-custodial contracts plus read-only indexers and a static frontend.

## Card lifecycle

1. **Parts** — the buyer mints the NAND gates a drawing needs.
2. **Tapeout** — the processor burns the gates and writes the netlist on chain.
3. **Edition** — the registry issues the next number for that drawing, up to its cap.
4. **Ownership** — the resulting ERC-721 circuit can be held, staked, wrapped, auctioned or used to back a buyer offer.

## Market

`CardAuctionV4` lists original numbered cards for BEM. Sellers set a reserve, duration and optional buy-now price; bids are escrowed; settlement pays the seller and the 1% fee to the treasury.

`TapeFoundryDrawingOfferBook` is deliberately separate:

- the buyer chooses a drawing, not a token id;
- the buyer's BEM is escrowed;
- any holder of a numbered original card of that drawing may accept and chooses which card to sell;
- one active offer per buyer per drawing;
- no automatic matching;
- 1% fee at fill.

Keeping the OfferBook separate means the existing auction market is untouched and no migration is required.

## Indexers

The production indexers and their runtime state are intentionally not part of this public extract. They are read-only services; the contracts remain the source of truth.

## Trust boundary

Contracts hold the assets and enforce the rules. Indexers and the static frontend are caches and can be rebuilt. The contract addresses in the README are public identifiers, not wallets.
