# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# TransferId mis-decoding breaks mint matching
**#2**
- Severity: Critical
- Validity: Invalid

## Targets
- _lzReceive (SETHAdapter)

## Affected Locations
- **SETHAdapter._lzReceive**: Single finding location

## Description

The adapter relies on a `transferId` embedded in the compose message to pair the ETH leg and the SETH leg of a cross‑chain transfer. `_send` encodes this id as `abi.encode(transferId)` and both the ETH‑OFT path (`lzCompose`) and the SETH‑OFT path (`_lzReceive`) are supposed to decode the same 32‑byte value. However, `lzCompose` loads the first word of `composeMsg` while `_lzReceive` reads a second word that does not exist for this payload. This inconsistency causes `_credit` to look up `ethQueue` under the wrong id, leaving the ETH leg and the pending mint permanently unpaired. The result is that ETH accumulates in the adapter while the destination never mints SETH for the user, and subsequent transfers can overwrite the stuck pending mint entry.

## Root cause

`_lzReceive` uses `mload(add(add(rawCompose, 32), 32))`, which reads the second word of the compose payload, while `_send` encodes only a single 32‑byte `transferId` and `lzCompose` decodes the first word.

## Impact

Cross‑chain transfers can be permanently stuck because the ETH leg and SETH leg are matched against different transfer ids. Users burn SETH on the source chain and the corresponding ETH collateral arrives, but no SETH is minted on the destination. The locked ETH remains stranded in the adapter with no recovery path, and repeated transfers can overwrite the pending mint for the wrong id.

## Remediation

**Status:** Incomplete

### Explanation

Modify `_lzReceive` to decode the compose payload exactly as `_send` encodes it, i.e., read the first 32‑byte word (or use `abi.decode(rawCompose, (bytes32))`) instead of the second word, so both legs use the same `transferId` and mint matching cannot desynchronize.

---

# Exchange-rate TOCTOU breaks mint matching
**#1**
- Severity: High
- Validity: Invalid

## Targets
- _processPendingMint (SETHAdapter)
- _credit (SETHAdapter)
- lzCompose (SETHAdapter)

## Affected Locations
- **SETHAdapter._processPendingMint**: This function recomputes `expectedEthAmount` using the current `ISETH(SETH).EXCHANGE_RATE()` and requires exact equality with already-queued values; fixing this location to use a stored snapshot/normalized amount (or add a reconciliation path) prevents rate drift from causing permanent reverts.
- **SETHAdapter._credit**: This function derives the ETH/SETH conversion from the current exchange rate during credit and reverts when it does not match previously queued ETH collateral; persisting the conversion basis at queue time (or matching on normalized units) here removes the TOCTOU mismatch that freezes credits.
- **SETHAdapter.lzCompose**: External callers via the LayerZero compose pathway trigger matching using message-controlled amounts; this function records the arriving value and immediately initiates processing that relies on a live exchange rate, exposing the timing mismatch across asynchronous message arrivals.

## Description

The adapter attempts to match two asynchronously-arriving cross-chain components (queued ETH collateral and a pending SETH mint) by recomputing the expected ETH amount from the current `ISETH(SETH).EXCHANGE_RATE()`. Because the two messages can arrive in different blocks and the exchange rate is mutable, the recomputed value can differ from the ETH amount that was originally queued or implied when the mint was initiated. The matching logic requires exact equality and reverts on mismatch, which rolls back the current processing step and leaves the previously queued state in a permanently unresolvable configuration. As a result, normal exchange-rate drift during message latency can freeze inbound mint finalization, and there is no reconciliation path to progress the queues. This is a classic cross-chain time-of-check/time-of-use mismatch caused by using live on-chain pricing for message matching instead of binding a rate or normalized amount into the message/queue state.

## Root cause

Mint/collateral matching derives the expected ETH amount from the current mutable `EXCHANGE_RATE()` at processing/credit time rather than storing a rate snapshot or normalized amount when the cross-chain transfer is initiated/queued.

## Impact

Legitimate inbound transfers can become permanently stuck, leaving ETH collateral locked in `ethQueue` and preventing users from receiving their minted SETH. Any actor able to influence the exchange rate (or even routine rate movement) can deliberately trigger mismatches to halt bridging and grief users until manual intervention or a coincidental rate return occurs.

## Remediation

**Status:** Incomplete

### Explanation

Store the exchange rate (or the computed ETH/SETH normalized amount) in the pending mint record when the cross-chain transfer is queued, and use that stored snapshot in `_processPendingMint` instead of the current `EXCHANGE_RATE()`, so matching is deterministic and cannot be broken by later rate changes.