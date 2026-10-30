# TapeFoundry

**A computer, one circuit at a time.**

TapeFoundry turns gate-level circuit drawings into numbered, verifiable cards on BNB Chain. Series 01 is the arithmetic unit: 11 drawings, 3,450 possible editions, each card backed by a real netlist and a fixed number of burned NAND gates.

This repository is the public, hackathon-facing extract of the project: contracts, tests and the architecture note. The live product is at **https://tapefoundry.xyz**.

## What is here

- `contracts/src/` — Solidity contracts for the card processor, edition registry, staking, auctions, buyer offers and related modules.
- `contracts/test/` — Foundry tests, including the auction and drawing-level offer book.
- `docs/ARCHITECTURE.md` — how the pieces fit together.
- `docs/market-ui-reference.html` — the market UI reference, kept as a single static file.

## Live contracts

Only public contract addresses are listed here. No wallets, signers, private keys or deployment credentials are included in this repository.

- **Auction market V4:** `0x78bC99D1B63F5b76625e12b0126B56774eC09874`
- **Drawing OfferBook V2:** `0xD038A00C6090328e36E8B19468884b09bD6f5A6C`
- **Card processor:** `0x5A4eaFf589C9e410260a61d658a893876710bA83`
- **Edition registry:** `0xB69215CE68792Eca5672b49196868369555EA181`

## Run the contracts

```bash
cd contracts
forge install foundry-rs/forge-std
forge test
```

The contracts are written for Solidity `^0.8.24` and BNB Smart Chain. Tests use mocks and local Foundry accounts only.

## Product surface

- **Cards:** each card is a real, frozen gate-level netlist; its edition number is issued by the registry.
- **Market:** original, numbered cards only; BEM settlement; 1% fee at settlement.
- **Buyer offers:** buyers post a standing offer for a drawing, lock BEM in the OfferBook, and any holder of a numbered original card of that drawing can accept and choose the card.
- **Games:** GateCrash is a separate parimutuel game on the same circuit-card ecosystem.

## Security

This repository intentionally contains **no private keys, seed phrases, keystores, wallet files, API keys or deployment secrets**. Do not add them. The production deployment uses environment/secret management outside this repository.

## Status

Hackathon extract. The live site and contracts are the source of truth; test coverage is Foundry-based.
