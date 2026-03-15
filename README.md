[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-black.svg)](https://www.gnu.org/licenses/agpl-3.0.en.html) [![solidity](https://img.shields.io/badge/solidity-%5E0.8.34-black)](https://docs.soliditylang.org/en/v0.8.34/) [![Foundry](https://img.shields.io/badge/Built%20with-Foundry-000000.svg)](https://getfoundry.sh/)

<p align="center">
  <img src="./banner.png" alt="StabilityETH by Isla Labs" width="100%">
</p>

# SETH ♢

StabilityETH (SETH) is an independent project inspired by Wrapped ETH, with a key difference: it turns TVL into an additional source of revenue for verified applications on both EVM and non-EVM chains.

## Key Features

- **1:100 Minting Ratio** — SETH can be minted at a 1:100 ratio to native ETH on any supported chain.

- **Performance Based Returns (PBR)** — Verified applications generate yield proportionally to their relative TVL.

- **Omnichain Asset** — SETH maintains its 1:100 collateralization rate across all chains during cross-chain transfers.

- **Open Eligibility** — All dApps are eligible for PBR if they meet the eligibility criteria.

## How It Works

SETH is fully collateralized by ETH at a 100:1 ratio (1 SETH = 0.01 ETH). Cross-chain transfers preserve this collateralization regardless of message arrival order. Verified applications receive Performance Based Returns in proportion to their share of total TVL, which does not rely on SETH holdings and instead can include any token staked in any contract, as long as the token has a market cap above $100m and the contract has a TVL above $100k.

## Security

Audited by [Zellic V12](https://zellic.ai/) AI scan — [report](./contracts/audit/zellic-V12-AI/latest/). No valid findings.

## Disclaimer

*These smart contracts and testing suite are being provided as is. No guarantee, representation or warranty is being made, express or implied, as to the safety or correctness of anything provided herein or through related user interfaces. This repository and related code have not been audited and as such there can be no assurance anything will work as intended, and users may experience delays, failures, errors, omissions, loss of transmitted information or loss of funds. The creators are not liable for any of the foregoing. Users should proceed with caution and use at their own risk.*