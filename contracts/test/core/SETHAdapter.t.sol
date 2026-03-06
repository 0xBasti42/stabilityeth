// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { Test } from "forge-std/Test.sol";
import { SETH } from "@core/SETH.sol";
import { SETHAdapter } from "@core/SETHAdapter.sol";
import { SendParam, MessagingFee } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";

// --------------------------------------------
//  Mocks
// --------------------------------------------

contract EndpointMock {
    mapping(address => address) public delegates;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }
}

contract EthOFTMock {
    function sendEth(address adapter) external payable {
        (bool ok,) = adapter.call{ value: msg.value }("");
        require(ok, "send failed");
    }
}

// --------------------------------------------
//  SETHAdapter Amount-Binding Tests
// --------------------------------------------

// forge-lint: disable-start(unsafe-typecast, mixed-case-variable)
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

    function test_credit_revertsWhenQueuedEthMismatchesMessageAmount() public {
        ethOft.sendEth{ value: 1 ether }(address(adapter));
        bytes memory composeEth = _buildComposeMessage(SRC_EID, 1 ether, 0);
        vm.prank(address(endpoint));
        adapter.lzCompose(address(ethOft), bytes32("eth"), composeEth, address(0), "");

        address recipient = makeAddr("recipient");
        uint256 sethAmountLD = 1000 ether;
        uint64 amountSD = uint64(sethAmountLD / adapter.decimalConversionRate());
        bytes memory sethMsg = _buildOftMessage(recipient, amountSD, 0);

        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidAmount.selector);
        adapter.lzReceive(origin, bytes32("seth"), sethMsg, address(0), "");
    }

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

    function _buildComposeMessage(uint32 srcEid, uint256 amountLD, uint256 transferId) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(transferId));
        return OFTComposeMsgCodec.encode(1, srcEid, amountLD, composeMsg);
    }

    function _buildOftMessage(address to, uint64 amountSD, uint256 transferId) internal view returns (bytes memory) {
        (bytes memory message,) = OFTMsgCodec.encode(bytes32(uint256(uint160(to))), amountSD, abi.encode(transferId));
        return message;
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
// forge-lint: disable-end(unsafe-typecast, mixed-case-variable)

// --------------------------------------------
//  SETHAdapter Access Control & Validation
// --------------------------------------------

// forge-lint: disable-start(unsafe-typecast, mixed-case-variable)
contract SETHAdapterAccessControlTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    uint32 constant SRC_EID = 1;
    uint32 constant DST_EID = 2;
    bytes32 constant PEER = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));

        adapter.setPeer(SRC_EID, PEER);
    }

    function test_receive_revertsWhenNotFromEthOft() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(adapter).call{ value: 1 ether }("");
        assertFalse(ok, "receive should revert when sender is not ETH_OFT");
    }

    function test_lzCompose_revertsWhenNotFromEndpoint() public {
        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory compose = _buildComposeMessage(SRC_EID, 10 ether, 0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(SETHAdapter.InvalidComposeSender.selector);
        adapter.lzCompose(address(ethOft), bytes32("x"), compose, address(0), "");
    }

    function test_lzCompose_revertsWhenFromNotEthOft() public {
        ethOft.sendEth{ value: 10 ether }(address(adapter));
        bytes memory compose = _buildComposeMessage(SRC_EID, 10 ether, 0);
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidComposeSender.selector);
        adapter.lzCompose(makeAddr("fakeEthOft"), bytes32("x"), compose, address(0), "");
    }

    function test_lzReceive_revertsWhenNotComposed() public {
        address recipient = makeAddr("recipient");
        uint64 amountSD = 1e6; // 1 in shared decimals
        (bytes memory message,) = OFTMsgCodec.encode(bytes32(uint256(uint160(recipient))), amountSD, "");
        Origin memory origin = Origin({ srcEid: SRC_EID, sender: PEER, nonce: 1 });
        vm.prank(address(endpoint));
        vm.expectRevert(SETHAdapter.InvalidComposeSender.selector);
        adapter.lzReceive(origin, bytes32("x"), message, address(0), "");
    }

    function _buildComposeMessage(uint32 srcEid, uint256 amountLD, uint256 transferId) internal view returns (bytes memory) {
        bytes memory composeMsg = abi.encodePacked(bytes32(uint256(uint160(address(this)))), abi.encode(transferId));
        return OFTComposeMsgCodec.encode(1, srcEid, amountLD, composeMsg);
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
// forge-lint: disable-end(unsafe-typecast, mixed-case-variable)

// --------------------------------------------
//  SETHAdapter addSethAdapter
// --------------------------------------------

contract SETHAdapterAddSethAdapterTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));
    }

    function test_addSethAdapter_revertsOnInvalidEid() public {
        vm.expectRevert(SETHAdapter.InvalidEid.selector);
        adapter.addSethAdapter(0, makeAddr("adapter2"), 1000 ether, 60);
    }

    function test_addSethAdapter_revertsOnZeroAddress() public {
        vm.expectRevert(SETHAdapter.InvalidAddress.selector);
        adapter.addSethAdapter(2, address(0), 1000 ether, 60);
    }

    function test_addSethAdapter_revertsOnInvalidRateLimitWindow() public {
        vm.expectRevert(SETHAdapter.InvalidRateLimitWindow.selector);
        adapter.addSethAdapter(2, makeAddr("adapter2"), 1000 ether, 10);
    }

    function test_addSethAdapter_revertsOnAdapterAlreadySet() public {
        adapter.addSethAdapter(2, makeAddr("adapter2"), 1000 ether, 60);
        vm.expectRevert(abi.encodeWithSelector(SETHAdapter.AdapterAlreadySet.selector, uint32(2)));
        adapter.addSethAdapter(2, makeAddr("adapter3"), 1000 ether, 60);
    }

    function test_addSethAdapter_success() public {
        address dstAdapter = makeAddr("adapter2");
        vm.expectEmit(true, true, true, true);
        emit SETHAdapter.NewChainAdded(2, dstAdapter);
        adapter.addSethAdapter(2, dstAdapter, 1000 ether, 60);
        assertEq(adapter.sethAdapters(2), dstAdapter);
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}

// --------------------------------------------
//  SETHAdapter quoteSend & send (revert paths)
// --------------------------------------------

contract SETHAdapterQuoteSendTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));

        adapter.addSethAdapter(2, makeAddr("dstAdapter"), 1000 ether, 60);
    }

    function test_quoteSend_revertsOnInvalidRecipient() public {
        SendParam memory param = SendParam({
            dstEid: 2,
            to: bytes32(0),
            amountLD: 100 ether,
            minAmountLD: 90 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.expectRevert(SETHAdapter.InvalidRecipient.selector);
        adapter.quoteSend(param, false);
    }

    function test_quoteSend_revertsOnSethAdapterNotSet() public {
        SendParam memory param = SendParam({
            dstEid: 999,
            to: bytes32(uint256(uint160(makeAddr("recipient")))),
            amountLD: 100 ether,
            minAmountLD: 90 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.expectRevert(abi.encodeWithSelector(SETHAdapter.SethAdapterNotSet.selector, uint32(999)));
        adapter.quoteSend(param, false);
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}

// forge-lint: disable-start(unsafe-typecast)
contract SETHAdapterSendTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));

        adapter.addSethAdapter(2, makeAddr("dstAdapter"), 1000 ether, 60);
        adapter.setPeer(2, bytes32(uint256(uint160(makeAddr("peer")))));

        seth.deposit{ value: 10 ether }();
    }

    function test_send_revertsOnInvalidRecipient() public {
        SendParam memory param = SendParam({
            dstEid: 2,
            to: bytes32(0),
            amountLD: 100 ether,
            minAmountLD: 90 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.expectRevert(SETHAdapter.InvalidRecipient.selector);
        adapter.send{ value: 0 }(param, MessagingFee(0, 0), address(this));
    }

    function test_send_revertsOnSethAdapterNotSet() public {
        SendParam memory param = SendParam({
            dstEid: 999,
            to: bytes32(uint256(uint160(makeAddr("recipient")))),
            amountLD: 100 ether,
            minAmountLD: 90 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.expectRevert(abi.encodeWithSelector(SETHAdapter.SethAdapterNotSet.selector, uint32(999)));
        adapter.send{ value: 0 }(param, MessagingFee(0, 0), address(this));
    }

    function test_send_revertsWhenPaused() public {
        adapter.pause();
        SendParam memory param = SendParam({
            dstEid: 2,
            to: bytes32(uint256(uint160(makeAddr("recipient")))),
            amountLD: 100 ether,
            minAmountLD: 90 ether,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        vm.expectRevert();
        adapter.send{ value: 0 }(param, MessagingFee(0, 0), address(this));
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
// forge-lint: disable-end(unsafe-typecast)

// --------------------------------------------
//  SETHAdapter Admin
// --------------------------------------------

contract SETHAdapterAdminTest is Test {
    SETH public seth;
    SETHAdapter public adapter;
    EndpointMock public endpoint;
    EthOFTMock public ethOft;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        endpoint = new EndpointMock();
        ethOft = new EthOFTMock();

        uint256 nonce = vm.getNonce(address(this));
        address predictedAdapter = _computeCreateAddress(address(this), nonce + 1);
        seth = new SETH(predictedAdapter);
        adapter = new SETHAdapter(address(seth), address(ethOft), address(endpoint), address(this));
    }

    function test_setMinTransferAmount_success() public {
        uint256 newMin = 1 ether;
        vm.expectEmit(true, true, true, true);
        emit SETHAdapter.MinTransferAmountSet(adapter.minTransferAmountLD(), newMin);
        adapter.setMinTransferAmount(newMin);
        assertEq(adapter.minTransferAmountLD(), newMin);
    }

    function test_setMinTransferAmount_revertsWhenNotOwner() public {
        vm.prank(makeAddr("attacker"));
        vm.expectRevert();
        adapter.setMinTransferAmount(1 ether);
    }

    function _computeCreateAddress(address deployer, uint256 nonce) internal pure returns (address) {
        require(nonce <= 0x7f, "nonce too large");
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce)));
        return address(uint160(uint256(hash)));
    }
}
