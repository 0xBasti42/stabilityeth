# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Caller ETH not enforced for outbound transfer
**#2**
- Severity: Critical
- Validity: Invalid

## Targets
- send (SETHAdapter)

## Affected Locations
- **SETHAdapter.send**: Single finding location

## Description

The `send` wrapper forwards directly into `_send`, which computes `ethAmount` and `ethFee.nativeFee` and then calls `IOFT(ETH_OFT).send` with `value: ethAmount + ethFee.nativeFee` without ever checking how much ETH the caller supplied. Because value is drawn from the adapter’s balance, any shortfall in `msg.value` is silently covered by ETH already held by the contract. This is particularly dangerous here because the adapter is expected to hold ETH from queued inbound transfers while waiting for the corresponding SETH message. An attacker can intentionally underfund `msg.value`, burn SETH, and still have the adapter pay the ETH leg from its own reserves. That drains ETH that belongs to other users’ pending transfers and can leave those transfers permanently undercollateralized or stuck.

## Root cause

`_send` spends `ethAmount + ethFee.nativeFee` from the contract balance without validating that the caller’s `msg.value` fully covers the required ETH outflow (and the provided `_fee` parameter is ignored).

## Impact

An attacker can repeatedly call `send` with little or no ETH and have the adapter subsidize their outbound ETH transfer using ETH held for other users. This directly depletes the adapter’s ETH reserves, breaking backing for queued inbound transfers and potentially causing those transfers to fail or become irrecoverable.

## Remediation

**Status:** Incomplete

### Explanation

Require the caller to provide `msg.value` that fully covers `ethAmount + ethFee.nativeFee` (using the provided `_fee` or a validated fee quote) before performing the outbound transfer, and reject or refund any mismatch. This prevents the contract from subsidizing sends with its own balance and ensures fees are paid by the caller.

---

# Mutable exchange rate breaks mint matching
**#3**
- Severity: Critical
- Validity: Invalid

## Targets
- _credit (SETHAdapter)
- _processPendingMint (SETHAdapter)
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._credit**: `_credit` recomputes `ethAmount` from the incoming `_amountLD` using the current `EXCHANGE_RATE()` and strictly compares it to the previously queued ETH amount in `ethQueue`, so any rate drift between the two legs causes a revert and makes the queued entry unfinalizable.
- **SETHAdapter._processPendingMint**: `_processPendingMint` re-derives `expectedEthAmount` from stored `PendingMint.amountLD` using the current `EXCHANGE_RATE()` and enforces strict equality against the queued ETH amount, so exchange-rate changes between message arrivals permanently strand `pendingMints`/`ethQueue` pairs.
- **SETHAdapter._send**: `_send` computes and emits/forwards amounts using `EXCHANGE_RATE()` at send time, but the receive path later recomputes expectations with a different (current) rate; this mismatch in rate-binding across legs is what makes later strict reconciliation fail after drift.

## Description

The adapter reconciles the ETH leg and the SETH leg of a cross-chain transfer by recomputing expected amounts using the current `ISETH(SETH).EXCHANGE_RATE()` and requiring strict equality with previously queued values. Because `EXCHANGE_RATE()` is rebasing/mutable, the ETH amount recorded in `ethQueue` and the SETH amount (`amountLD`) recorded in `pendingMints` can be based on different historical rates depending on message arrival order and transit time. Any drift between those rates causes `_credit`/`_processPendingMint` to revert with an invalid-amount condition even though both halves of the transfer have arrived. The revert leaves `ethQueue` and/or `pendingMints` entries intact, but also makes them effectively unmatchable going forward because the same strict check will continue to fail under the new rate. This creates a permanent stuck-state for affected transfers unless there is manual recovery logic or an unlikely rate movement back to the exact prior ratio.

## Root cause

Receive-side reconciliation uses a live, mutable `EXCHANGE_RATE()` with strict equality instead of binding the transfer to a rate/amount snapshot (or allowing bounded drift) taken at initiation.

## Impact

Legitimate in-flight transfers can become permanently stuck, trapping ETH in `ethQueue` and preventing recipients from receiving minted SETH. An attacker who can trigger, time, or influence exchange-rate updates (or simply observe and act around natural rebases) can reliably grief users by causing queued transfers to revert and remain stranded, degrading bridge availability.

## Remediation

**Status:** Incomplete

### Explanation

Bind each transfer to an immutable exchange‑rate snapshot (or expected mint amount) captured at initiation and include it in the cross‑chain message, then have `_credit` verify against that snapshot or allow a small bounded drift instead of recomputing with the live `EXCHANGE_RATE()` and requiring strict equality. This removes dependence on mutable rates and prevents legitimate in‑flight transfers from being permanently rejected.

---

# TransferId spoofing hijacks queued ETH
**#4**
- Severity: Critical
- Validity: Invalid

## Targets
- _lzReceive (SETHAdapter)

## Affected Locations
- **SETHAdapter._lzReceive**: Single finding location

## Description

This is a V-1 cross-chain trust boundary issue because `_lzReceive` blindly parses `transferId` from the composed payload and never binds it to `_guid` or a trusted sender. The identifier is therefore attacker-controlled input that becomes the sole key used by `_credit` to locate `ethQueue[srcEid][transferId]` and decide whether to mint. If a queued ETH transfer already exists for some identifier, an attacker can craft a message with that same `transferId`, choose their own `sendTo`, and supply a matching amount. `_credit` will then delete the queue entry and mint SETH to the attacker, leaving the legitimate recipient with a stuck transfer that can no longer be completed.

## Root cause

The transfer identifier is taken directly from untrusted message bytes and used as the only correlation key without being derived from or authenticated by `_guid`/origin.

## Impact

An attacker can redirect SETH mints backed by other users’ queued ETH to their own address. Victims’ transfers will fail or remain permanently pending after the queue entry is consumed, effectively stealing the bridged value.

## Remediation

**Status:** Incomplete

### Explanation

Derive and validate the queue correlation key from trusted data instead of trusting the payload: bind each queued transfer to the `_guid`/origin when enqueuing, and in `_lzReceive` use that bound identifier (or verify the payload `transferId` matches the stored one for that `_guid` and origin) before releasing/minting, rejecting mismatches so spoofed IDs cannot consume others’ queue entries.

---

# Transfer ID decoded from wrong offset
**#5**
- Severity: Critical
- Validity: Invalid

## Targets
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._send**: Single finding location

## Description

The adapter encodes the `transferId` as the sole word in the composed payload during `_send`, but `_lzReceive` reads the second word of the compose message instead of the first. `lzCompose` correctly decodes the first word and stores the ETH amount under the intended `transferId`, while `_credit` stores the pending mint under a different (often zero) id. Because `ethQueue` and `pendingMints` are keyed by `transferId`, these two halves never line up and `_processPendingMint` never mints SETH. The result is that ETH sent by the bridge remains locked in the adapter while the sender’s SETH has already been burned. This breaks normal transfers and can permanently strand user funds on the destination chain.

## Root cause

Inconsistent compose-message decoding: `_lzReceive` uses `mload(add(add(rawCompose, 32), 32))` even though `_send` only encodes a single 32‑byte `transferId`.

## Impact

Bridged transfers fail to reconcile, leaving ETH locked in the adapter and no SETH minted to the recipient. Users who initiate a transfer can lose access to the value they burned on the source chain, and the bridge becomes nonfunctional for normal traffic.

## Remediation

**Status:** Incomplete

### Explanation

Modify `_lzReceive` to decode the `transferId` from the correct offset for a single‑word payload (i.e., read the first 32 bytes after the length), or alternatively update `_send` to encode the extra word that `_lzReceive` expects; ensure both sides use the same single‑word compose format so the transfer ID is parsed consistently.

---

# SETH mint allows ETH underpayment via rounding
**#1**
- Severity: Low
- Validity: Unreviewed

## Targets
- mint (SETH)

## Affected Locations
- **SETH.mint**: `mint` calculates `expectedEth` with integer division (`amount / EXCHANGE_RATE`) and only checks `msg.value` against this truncated result, so non-multiple `amount`s can be minted with insufficient (or zero) ETH. Fixing this location by requiring `amount % EXCHANGE_RATE == 0` or using a round-up (`ceilDiv`) ETH calculation restores the backing invariant at the point where supply is created.

## Description

`SETH.mint` computes the required ETH as `expectedEth = amount / EXCHANGE_RATE`, which uses integer floor division. When `amount` is not an exact multiple of `EXCHANGE_RATE`, `expectedEth` is truncated, and the subsequent equality check against `msg.value` permits paying less ETH than the fixed exchange rate implies (including minting small “dust” amounts for 0 ETH). The function then mints the full `amount` of SETH without enforcing divisibility or rounding the ETH requirement up, breaking the intended backing invariant. These unbacked tokens can be accumulated into redeemable quantities and later exchanged for real ETH via the burn/withdraw path, even though the original mint did not provide proportional collateral. Over time this creates systemic undercollateralization and shifts losses onto honest holders or causes withdrawals to fail when reserves are depleted.

## Root cause

`mint` derives `expectedEth` using floor division and does not enforce exact divisibility (or round up), allowing SETH minting without paying the full ETH required by the exchange rate.

## Impact

An attacker (or malicious/compromised bridge adapter) can mint SETH while underpaying ETH, creating unbacked supply that can be sold or redeemed. By aggregating the underpaid mints into redeemable chunks, they can withdraw real ETH and drain collateral, eventually causing insolvency and failed withdrawals for legitimate users.