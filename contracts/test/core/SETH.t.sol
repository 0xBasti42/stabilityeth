// SPDX-License-Identifier: BUSL-1.1
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
// SETH Unit Tests
// -----------------------------------------------------------------------------

contract SETHTest is Test {
    SETH public seth;
    address public adapter;

    receive() external payable { }

    function setUp() public {
        adapter = makeAddr("adapter");
        seth = new SETH(adapter);
    }

    function test_deposit_mintsAt100to1() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        assertEq(seth.balanceOf(address(this)), 1000 ether);
        assertEq(address(seth).balance, 10 ether);
    }

    function test_withdraw_burnsAndSendsEth() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        uint256 balanceBefore = address(this).balance;
        seth.withdraw(100 ether); // 100 SETH = 1 ETH
        assertEq(seth.balanceOf(address(this)), 900 ether);
        assertEq(address(this).balance - balanceBefore, 1 ether);
        assertEq(address(seth).balance, 9 ether);
    }

    function test_transfer_appliesFee() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address recipient = makeAddr("recipient");
        seth.transfer(recipient, 100 ether);
        // 0.3% fee on 100 ether = 0.3 ether SETH
        assertEq(seth.balanceOf(recipient), 99.7 ether);
        assertEq(seth.accruedFeesInEth(), 0.003 ether);
    }

    function test_isFullyBacked_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        address recipient = makeAddr("recipient");
        seth.transfer(recipient, 100 ether); // accrues fees
        (bool fullyBacked, uint256 ratioBps) = seth.isFullyBacked();
        assertTrue(fullyBacked);
        assertGe(ratioBps, 10000);
    }

    function test_ethCollateral_excludesAccruedFees() public {
        vm.deal(address(this), 10 ether);
        seth.deposit{ value: 10 ether }();
        seth.transfer(makeAddr("r"), 100 ether);
        uint256 collateral = seth.ethCollateral();
        uint256 accrued = seth.accruedFeesInEth();
        assertEq(collateral, address(seth).balance - accrued);
    }
}

// -----------------------------------------------------------------------------
// SETHAdapter Amount-Binding Tests (Audit Finding #2)
// -----------------------------------------------------------------------------

contract SETHAdapterAmountBindingTest is Test {
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

    /// @notice Overwriting ethQueue with same transferId should revert (lzCompose check)
    function test_lzCompose_revertsOnDuplicateTransferId() public {
        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory compose1 = _buildComposeMessage(SRC_EID, 10 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("g1"), compose1, address(0), "");
        assertEq(adapter.ethQueue(SRC_EID, 0), 10 ether);

        ethOft.sendEth{ value: 1 ether }(address(adapter));
        bytes memory compose2 = _buildComposeMessage(SRC_EID, 1 ether, 0);
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzCompose(address(ethOft), bytes32("g2"), compose2, address(0), "");
    }

    /// @notice Mismatched ETH amount vs SETH amount should revert (_credit check)
    function test_credit_revertsWhenQueuedEthMismatchesMessageAmount() public {
        ethOft.sendEth{ value: 1 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 1 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");

        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether; // 10 ETH worth
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");
    }

    /// @notice Duplicate SETH message for same transferId should revert (_credit pendingMints check)
    function test_credit_revertsOnDuplicatePendingMint() public {
        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether;
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth1"), sethMsg, address(0), "");

        address attacker = makeAddr("attacker");
        bytes memory attackerMsg = _buildOftMessage(attacker, amountSD, 0);
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzReceive(origin, bytes32("seth2"), attackerMsg, address(0), "");
    }

    /// @notice ETH amount mismatch in _processPendingMint should revert
    function test_processPendingMint_revertsWhenEthAmountMismatches() public {
        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether;
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");

        ethOft.sendEth{ value: 5 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 5 ether, 0);
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");
    }

    /// @notice Happy path: ETH first, then SETH - should mint correctly
    function test_ethFirstThenSeth_mintsCorrectly() public {
        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 10 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");

        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether;
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");

        assertEq(seth.balanceOf(recipient), 1000 ether);
        assertEq(adapter.ethQueue(SRC_EID, 0), 0);
        assertEq(address(seth).balance, 10 ether);
    }

    /// @notice Happy path: SETH first, then ETH - should mint correctly
    function test_sethFirstThenEth_mintsCorrectly() public {
        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether;
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");

        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 10 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");

        assertEq(seth.balanceOf(recipient), 1000 ether);
        assertEq(adapter.ethQueue(SRC_EID, 0), 0);
        assertEq(address(seth).balance, 10 ether);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

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
