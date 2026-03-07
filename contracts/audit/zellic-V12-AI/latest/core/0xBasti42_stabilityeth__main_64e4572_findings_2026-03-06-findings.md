# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Unvalidated transferId allows ETH queue hijack
**#1**
- Severity: Critical
- Validity: Invalid

## Targets
- _lzReceive (SETHAdapter)

## Affected Locations
- **SETHAdapter._lzReceive**: Single finding location

## Description

`_lzReceive` accepts any composed OFT message and extracts the `transferId` from the raw compose bytes using an unchecked assembly read. It does not verify that the compose payload was produced by a trusted adapter or that the `transferId` is bound to the message’s `_guid` or sender. The function stores this `transferId` in `_creditTransferId`, and `_credit` then uses it to look up `ethQueue[srcEid][transferId]` and release queued ETH while minting SETH to the `toAddress` from the message. Because the `transferId` is fully attacker-controlled, a sender can choose an existing transferId with queued ETH and craft a message with a matching amount to claim that collateral. The legitimate transfer for that transferId will then fail or remain pending once the queue entry is consumed.

## Root cause

The compose payload is trusted as the authoritative `transferId` without validating its sender or cryptographically binding it to the cross-chain message.

## Impact

An attacker can consume another user’s queued ETH collateral and mint SETH to themselves by replaying that transferId. The original sender’s transfer becomes stuck because the queue entry is deleted, resulting in loss of their ETH leg and denial of their cross-chain transfer.

## Remediation

**Status:** Incomplete

### Explanation

Bind the `transferId` to the authenticated LayerZero message instead of trusting the compose payload: derive/lookup the expected `transferId` from the message’s guid/srcEid/sender and verify it matches the queued entry, reverting on mismatch. Ensure `_lzReceive` only processes messages from the trusted endpoint/peer and rejects any compose payload that is not cryptographically tied to the original transfer.

---

# Rounding down ETH collateral
**#2**
- Severity: Critical
- Validity: Invalid

## Targets
- _credit (SETHAdapter)

## Affected Locations
- **SETHAdapter._credit**: Single finding location

## Description

The function converts the incoming SETH amount to an ETH collateral amount using `ethAmount = _amountLD / ISETH(SETH).EXCHANGE_RATE()` and then mints the full `_amountLD` once a queued ETH leg matches that value. This conversion uses integer division, so any remainder is silently truncated. When a sender bridges an amount that is not an exact multiple of the exchange rate, the ETH leg will carry only the truncated amount and `_credit` will still accept it and mint the full SETH amount. The result is that the destination chain receives less ETH collateral than is required for the minted SETH. Over time this creates under‑collateralized supply that can be redeemed for more ETH than was deposited.

## Root cause

The ETH collateral amount is derived via integer division without enforcing divisibility or rounding up, but the full `_amountLD` is still minted.

## Impact

An attacker can repeatedly bridge amounts that produce a remainder, minting SETH backed by insufficient ETH. They can then redeem those tokens for more ETH than was actually moved, draining collateral from other users and leaving the destination pool under‑collateralized.

## Remediation

**Status:** Incomplete

### Explanation

Modify `_credit` to mint only the amount actually backed by ETH collateral: either require `_amountLD` to be an exact multiple of the conversion factor (revert on remainder) or truncate/return the dust and mint based on the converted collateral amount, never on the original `_amountLD`.

---

# TransferId decoded from wrong word
**#3**
- Severity: Critical
- Validity: Invalid

## Targets
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._send**: Single finding location

## Description

The adapter encodes a `transferId` as a single 32‑byte word in `_send` and relies on both `lzCompose` and `_lzReceive` to decode the same value so the ETH and SETH legs can be matched. `lzCompose` correctly reads the first word of the compose payload, but `_lzReceive` reads the second word. Because the payload is only one word long, `_lzReceive` always decodes `transferId` as zero. This means ETH is queued under the real transferId while `_credit` always looks under transferId `0`, so the two legs never reconcile and minting never completes. The result is that cross‑chain transfers revert or remain permanently pending even though funds were burned on the source chain.

## Root cause

The compose payload is `abi.encode(transferId)` (one word), but `_lzReceive` reads the second word of the payload instead of the first, producing a mismatched transferId.

## Impact

Users can burn SETH and pay fees but never receive minted SETH on the destination chain, with the ETH collateral trapped in the adapter. The bridge can be effectively bricked for all transfers because every incoming SETH message uses transferId `0` and never matches the queued ETH leg.

## Remediation

**Status:** Incomplete

### Explanation

Modify `_lzReceive` to decode the `transferId` from the first word of the compose payload (or use `abi.decode(payload, (uint256))`) so it matches the `abi.encode(transferId)` layout, and ensure any future payload changes update both encoding and decoding consistently.

---

# Exchange-rate drift bricks pending transfers
**#4**
- Severity: Critical
- Validity: Invalid

## Targets
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._send**: Single finding location

## Description

The adapter converts between SETH and ETH using `ISETH(SETH).EXCHANGE_RATE()` on both the send and receive paths. `_send` computes the ETH amount to bridge using the current exchange rate and embeds that ETH amount in the ETH OFT message. When the SETH leg is processed, `_credit` and `_processPendingMint` recompute the expected ETH amount using the *current* exchange rate and require an exact match to the queued ETH amount. Because the ETH and SETH messages can arrive in different blocks, any change in `EXCHANGE_RATE()` between them causes a strict mismatch and a revert. This leaves either `pendingMints` or `ethQueue` populated forever and prevents the transfer from completing.

## Root cause

The exchange rate is not snapshotted at send time or included in the message; the receive path recomputes the expected ETH amount using whatever rate is current and enforces exact equality.

## Impact

If the exchange rate changes while a transfer is in flight, the minting step reverts and the ETH collateral remains locked in the adapter while the user receives no SETH. Any party able to update the exchange rate (or natural rebases) can systematically grief or freeze cross‑chain transfers.

## Remediation

**Status:** Incomplete

### Explanation

Include the exchange rate (or the computed ETH amount to mint) in the cross‑chain message at send time and use that snapshot on receive, so minting is based on the original rate rather than recalculating with the current one. Remove the exact‑equality check against a fresh rate and instead validate against the sent value (optionally with a defined tolerance) to prevent drift from reverting transfers.