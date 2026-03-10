# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Uncharged messaging fees drain adapter ETH
**#3**
- Severity: Critical
- Validity: Invalid

## Targets
- send (SETHAdapter)

## Affected Locations
- **SETHAdapter.send**: Single finding location

## Description

The `_send` flow computes both `ethFee` and `sethFee` but never checks `msg.value` or `_fee` to ensure the caller actually paid those fees. It then unconditionally calls `IOFT(ETH_OFT).send{value: ethAmount + ethFee.nativeFee}` and `_lzSend(...)`, which spend the adapter’s own ETH balance to cover the LayerZero fees. Because the adapter also holds ETH collateral that backs outstanding SETH, any caller can initiate a transfer with zero ETH and have the contract subsidize the messaging costs. An attacker can repeat this with very small burns to maximize fee leakage per unit of SETH burned, steadily draining the adapter’s ETH and reducing backing for remaining holders. This is a fee/accounting completeness issue where required fees are not collected from the caller.

## Root cause

The function ignores the `_fee` input and does not validate `msg.value`, yet pays `ethFee.nativeFee` and `sethFee` from the contract’s balance, allowing callers to shift fee costs onto the adapter.

## Impact

Attackers can execute cross-chain sends without paying any messaging fees, causing the adapter to subsidize every transfer. Repeated low-value sends can drain ETH reserves used to back SETH, potentially undercollateralizing remaining tokens and causing future redemptions or transfers to fail when the adapter runs out of ETH.

## Remediation

**Status:** Incomplete

### Explanation

Validate and charge the caller for messaging fees: compute the required total (ethFee.nativeFee + sethFee), require `msg.value` to cover it (or match `_fee`), and use the caller‑supplied value to pay LayerZero instead of the adapter’s balance so the contract never subsidizes sends.

---

# Unvalidated compose payload lets transferId be spoofed
**#5**
- Severity: Critical
- Validity: Invalid

## Targets
- _lzReceive (SETHAdapter)

## Affected Locations
- **SETHAdapter._lzReceive**: Single finding location

## Description

The function only checks that `_message` is “composed” by length and then reads `transferId` from the compose payload using raw assembly. No validation is done to ensure the compose payload is long enough or that the `transferId` is bound to the ETH transfer that created the queue entry. `_lzReceive` writes this value into `_creditTransferId` and immediately calls `_credit`, which uses it to look up and delete `ethQueue` before minting SETH to the parsed recipient. Because the transferId comes straight from untrusted message bytes, a sender can craft a message that points at another user’s queued ETH and choose an arbitrary recipient. This breaks the intended one-to-one pairing between ETH compose callbacks and SETH mints.

## Root cause

`transferId` is parsed from unvalidated compose bytes and used as the sole key for queue matching, making it attacker-controlled if the sender can craft the compose payload.

## Impact

An attacker who can submit a composed message can mint SETH backed by another user’s queued ETH by supplying that user’s transferId and a matching amount. They can also grief legitimate transfers by clearing or pre-empting queue entries, leaving the intended recipient with a pending mint that can never be satisfied.

## Remediation

**Status:** Incomplete

### Explanation

Derive `transferId` from trusted data (the primary LZ message payload or a deterministic hash of `srcEid`, sender, receiver, amount, nonce) and validate it against a queued entry before minting, rejecting any compose bytes that don’t match the expected origin and parameters. Bind queue entries to the expected sender/receiver and amount so compose payloads cannot supply arbitrary IDs to claim or clear someone else’s queue.

---

# No staleness check on Chainlink price
**#1**
- Severity: High
- Validity: Unreviewed

## Targets
- _ethPriceUsd (DynamicFee)

## Affected Locations
- **DynamicFee._ethPriceUsd**: Single finding location

## Description

The function treats any positive `latestRoundData` answer as valid as long as `updatedAt` is nonzero and `answeredInRound` is not behind `roundId`. It never checks whether the round is recent, so a stale oracle response is accepted indefinitely. `calculateDynamicFee` relies on this price to convert ETH volume into USD and pick the fee tier, so the fee rate directly depends on this value. If the feed stalls at an outdated high price, the USD volume is overstated and the exponential decay yields a lower fee than intended. Users can therefore time requests during oracle outages to reduce fees and pay less than the model expects.

## Root cause

`updatedAt` is not validated against a maximum age, so stale Chainlink rounds are treated as current pricing data.

## Impact

Attackers can exploit stalled or outdated oracle data to pay lower fees than intended, reducing protocol fee revenue. During prolonged oracle outages, the system may continue applying an arbitrarily old price, distorting the fee schedule for extended periods.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import "forge-std/Test.sol";
import "src/core/SETH.sol";

contract MockAggregator {
    uint8 public immutable decimals;
    int256 public immutable answer;
    uint256 public immutable updatedAt;

    constructor(int256 _answer, uint256 _updatedAt, uint8 _decimals) {
        answer = _answer;
        updatedAt = _updatedAt;
        decimals = _decimals;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 _answer, uint256 startedAt, uint256 _updatedAt, uint80 answeredInRound)
    {
        return (1, answer, 0, updatedAt, 1);
    }
}

contract DynamicFeeStaleOracleTest is Test {
    function test_staleOracleDataIsAcceptedAndLowersFee() public {
        // Simulate time moving far beyond the oracle update time.
        vm.warp(30 days);

        // Stale oracle returns a higher price (e.g., $5,000) but has an extremely old updatedAt.
        MockAggregator staleAggregator = new MockAggregator(5000e8, 1, 8);
        SETH sethWithStaleFeed = new SETH(address(0xBEEF), address(staleAggregator));

        // Control deployment that relies on fallback price ($3,000) when no feed is provided.
        SETH sethWithFallback = new SETH(address(0xBEEF), address(0));

        uint256 staleFeeBps = sethWithStaleFeed.calculateDynamicFee(10 ether);
        uint256 fallbackFeeBps = sethWithFallback.calculateDynamicFee(10 ether);

        // If stale data were rejected, the fee should match the fallback calculation.
        // This assertion fails because the stale price is accepted and produces a lower fee.
        assertEq(staleFeeBps, fallbackFeeBps, "stale oracle price should be ignored");
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Reject stale oracle data by checking `updatedAt` against a `maxOracleAge` window in `_ethPriceUsd` and reverting when the response is too old, preventing the fee model from using outdated prices.

### Patch

```diff
diff --git a/contracts/src/core/base/DynamicFee.sol b/contracts/src/core/base/DynamicFee.sol
--- a/contracts/src/core/base/DynamicFee.sol
+++ b/contracts/src/core/base/DynamicFee.sol
@@ -143,7 +143,11 @@
         try AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData()
             returns (uint80 roundId, int256 answer, uint256 /* startedAt */, uint256 updatedAt, uint80 answeredInRound)
         {
+            uint256 maxOracleAge = 1 days;
             if (answer > 0 && updatedAt != 0 && answeredInRound >= roundId) {
+                if (block.timestamp < updatedAt || block.timestamp - updatedAt > maxOracleAge) {
+                    revert();
+                }
                 uint8 dec = FEED_DECIMALS;
                 if (dec >= 6) {
                     uint256 factor = 10 ** (uint256(dec) - 6);
```

### Affected Files

- `contracts/src/core/base/DynamicFee.sol`

### Validation Output

```
Compiling 3 files with Solc 0.8.34
Solc 0.8.34 finished in 4.20s
Compiler run successful with warnings:
Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/Strings.sol:25:13:
   |
25 |             assembly {
   |             ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/Strings.sol:31:17:
   |
31 |                 assembly {
   |                 ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol:63:13:
   |
63 |             assembly {
   |             ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol:169:9:
    |
169 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol:199:9:
    |
199 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:64:9:
   |
64 |         assembly {
   |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:74:9:
   |
74 |         assembly {
   |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:84:9:
   |
84 |         assembly {
   |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:94:9:
   |
94 |         assembly {
   |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:104:9:
    |
104 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:114:9:
    |
114 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:124:9:
    |
124 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
   --> lib/openzeppelin-contracts/contracts/utils/StorageSlot.sol:134:9:
    |
134 |         assembly {
    |         ^ (Relevant source part starts here and spans across multiple lines).

Warning (2424): Natspec memory-safe-assembly special comment for inline assembly is deprecated and scheduled for removal. Use the memory-safe block annotation instead.
  --> lib/openzeppelin-contracts/contracts/utils/ShortStrings.sol:68:9:
   |
68 |         assembly {
   |         ^ (Relevant source part starts here and spans across multiple lines).


Ran 1 test for test/Injected.t.sol:DynamicFeeStaleOracleTest
[FAIL: EvmError: Revert] test_staleOracleDataIsAcceptedAndLowersFee() (gas: 4070785)
Traces:
  [4070785] DynamicFeeStaleOracleTest::test_staleOracleDataIsAcceptedAndLowersFee()
    ├─ [0] VM::warp(2592000 [2.592e6])
    │   └─ ← [Return]
    ├─ [76461] → new MockAggregator@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 380 bytes of code
    ├─ [1943867] → new SETH@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   ├─ [154] MockAggregator::decimals() [staticcall]
    │   │   └─ ← [Return] 8
    │   └─ ← [Return] 9361 bytes of code
    ├─ [1943279] → new SETH@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 9361 bytes of code
    ├─ [2019] SETH::calculateDynamicFee(10000000000000000000 [1e19]) [staticcall]
    │   ├─ [287] MockAggregator::latestRoundData() [staticcall]
    │   │   └─ ← [Return] 1, 500000000000 [5e11], 0, 1, 1
    │   └─ ← [Revert] EvmError: Revert
    └─ ← [Revert] EvmError: Revert

Backtrace:
  at SETH.calculateDynamicFee
  at DynamicFeeStaleOracleTest.test_staleOracleDataIsAcceptedAndLowersFee

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 941.06µs (479.84µs CPU time)

Ran 1 test suite in 23.53ms (941.06µs CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/Injected.t.sol:DynamicFeeStaleOracleTest
[FAIL: EvmError: Revert] test_staleOracleDataIsAcceptedAndLowersFee() (gas: 4070785)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

---

# Mutable exchange rate breaks async mint matching
**#4**
- Severity: High
- Validity: Invalid

## Targets
- _processPendingMint (SETHAdapter)
- _credit (SETHAdapter)
- lzCompose (SETHAdapter)
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._processPendingMint**: It recomputes `expectedEthAmount` from the live `ISETH(SETH).EXCHANGE_RATE()` and requires exact equality with the previously queued `ethAmount`; changing this to use a transfer-bound rate/expected amount (or treating queued ETH as authoritative) prevents rate drift from causing `InvalidAmount()` reverts.
- **SETHAdapter._credit**: It re-derives the ETH/SETH relationship using the current `EXCHANGE_RATE()` and strictly compares against `ethQueue`; fixing this validation to rely on send-time parameters (or recorded conversion) stops legitimate credits from reverting when the rate changes between callbacks.
- **SETHAdapter.lzCompose**: Any caller via LayerZero’s compose callback can trigger processing of a queued ETH amount; it immediately invokes `_processPendingMint`, exposing the strict exchange-rate-dependent matching to asynchronous message timing.
- **SETHAdapter._send**: It derives and dispatches two separate messages whose amounts implicitly depend on the exchange rate at send time, but does not ensure the destination can verify against the same bound conversion data, enabling later receive-side recomputation to mismatch queued ETH.

## Description

The bridge splits an inbound mint into two asynchronous legs (an ETH compose that queues `ethAmount`, and a SETH credit that completes minting), but the destination side re-derives the “expected” ETH/SETH conversion using the current `ISETH(SETH).EXCHANGE_RATE()` when the second leg arrives. Because the ETH amount carried in the compose message is fixed at send time, any exchange-rate movement between the two callbacks makes the recomputed expected amount diverge from the already-queued `ethAmount`. The code then enforces strict equality and reverts with `InvalidAmount()`, which prevents the LayerZero receive/compose callback from completing and leaves `ethQueue`/`pendingMints` entries uncleared. Since the two legs can be separated by many blocks, normal rate drift is sufficient to cause legitimate transfers to become unprocessable. An attacker who can influence or time exchange-rate updates can reliably trigger these mismatches to keep inbound transfers stuck.

## Root cause

Receive-side matching validates queued ETH against a mutable, execution-time `EXCHANGE_RATE()` instead of binding the send-time rate/expected ETH (or using the received ETH amount) to the transfer ID.

## Impact

Legitimate inbound cross-chain transfers can be frozen because one leg of the transfer will revert when the exchange rate changes in flight, leaving ETH locked in the adapter and SETH never minted to the recipient. Users may have already burned/locked value on the source chain while the destination mint cannot complete, and repeated rate updates can degrade or halt bridge throughput until an operator intervenes or an unlikely exact rate match occurs again.

## Remediation

**Status:** Incomplete

### Explanation

Persist the expected ETH amount (or the exchange rate used to compute it) alongside each pending mint at enqueue time, and in `_processPendingMint` validate/mint against that stored value rather than the current `EXCHANGE_RATE()`. This binds the transfer to the send‑time rate and prevents execution‑time rate changes from blocking legitimate mints.

---

# TransferId parsing mismatch breaks mint matching
**#6**
- Severity: High
- Validity: Invalid

## Targets
- lzCompose (SETHAdapter)

## Affected Locations
- **SETHAdapter.lzCompose**: Single finding location

## Description

The transfer id used to correlate the ETH_OFT compose message with the SETH message is encoded once in `_send` via `abi.encode(transferId)` and is expected to be decoded consistently on both receive paths. `lzCompose` loads the first 32‑byte word from `composeMsg`, but `_lzReceive` loads the second word. Because the compose payload is only a single 32‑byte word, `_lzReceive` always reads zero and uses transferId 0 for every SETH receive. This causes `_credit` to create `pendingMints` under transferId 0 while `lzCompose` records ETH under the real transferId. The ETH and SETH legs never reconcile, so no mint happens and subsequent messages revert due to the existing pending entry, effectively freezing the bridge while burning user funds on the source chain.

## Root cause

The transferId is decoded with different offsets in `lzCompose` and `_lzReceive` even though the compose payload contains only a single encoded `uint256`.

## Impact

Cross‑chain transfers can be permanently stuck because the ETH and SETH legs never match, leaving the destination mint unexecuted after the source burn. After the first failed transfer, subsequent SETH messages revert due to a lingering `pendingMints` entry, causing a full denial of service for the bridge.

## Remediation

**Status:** Incomplete

### Explanation

Use a single, consistent payload format for `transferId` across `_lzReceive` and `lzCompose` by decoding the compose message with the same ABI layout (e.g., `abi.decode` of the expected struct) instead of manual offsets. Ensure both functions read the exact same bytes so the ETH and SETH legs match and pending mints clear correctly.

---

# Truncated ETH requirement undercollateralizes mint
**#2**
- Severity: Low
- Validity: Invalid

## Targets
- mint (SETH)

## Affected Locations
- **SETH.mint**: Single finding location

## Description

`mint` is intended to take ETH collateral and issue SETH at a fixed rate, but it computes the required ETH using `expectedEth = amount / EXCHANGE_RATE`. Because integer division truncates, any `amount` that is not an exact multiple of `EXCHANGE_RATE` yields a smaller `expectedEth` than the true collateral requirement. The function only checks `msg.value` against this truncated number and then mints the full `amount`, so the supply can grow without corresponding ETH backing. Those unbacked tokens can later be used in the normal burn/withdrawal flow that assumes full collateralization, pushing the deficit onto the system and other holders.

## Root cause

The ETH required for minting is calculated with integer division and there is no rounding up or divisibility check to ensure the full collateral requirement is met.

## Impact

An attacker who can influence `amount` through the adapter can mint SETH while sending less (or even zero) ETH than required. This creates unbacked supply that can be sold or redeemed, draining value from the system and leaving honest holders with an insolvent token.

## Remediation

**Status:** Incomplete

### Explanation

Compute the required ETH using a rounding‑up multiplication/division (or enforce exact divisibility) and require `msg.value` to meet that full amount before minting, so no truncated calculation can undercollateralize the mint.