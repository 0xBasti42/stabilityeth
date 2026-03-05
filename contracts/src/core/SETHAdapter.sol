// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";
import { IOAppMsgInspector } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppMsgInspector.sol";

interface ISETH {
    function EXCHANGE_RATE() external view returns (uint256);
    function releaseCollateral(uint256 sethAmount) external;
    function receiveCollateral() external payable;
}

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which handles cross-chain collateral flows.
 * @dev Uses transferId in composeMsg to match ETH and SETH messages; only mints when ETH has arrived.
 */
contract SETHAdapter is MintBurnOFTAdapter, ILayerZeroComposer {
    address public seth;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice ETH OFT address on srcChain
    address public ethOft;

    /// @notice SETHAdapter addresses on dstChains
    mapping(uint32 => address) public sethAdapters;

    /// @notice Monotonic transfer ID for correlating ETH and SETH messages
    uint256 public transferIdCounter;

    /// @notice ETH received for transferId (from ethOft lzCompose)
    mapping(uint256 => uint256) public ethQueue;

    /// @notice Pending mints when SETH arrives before ETH
    struct PendingMint {
        address to;
        uint256 amountLD;
    }
    mapping(uint256 => PendingMint) public pendingMints;

    /// @dev Set by _lzReceive before calling _credit; read by _credit for transferId-based matching
    uint256 private _creditTransferId;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    error InvalidAddress();
    error DirectDepositsDisabled();
    error SethAdapterNotSet(uint32 eid);
    error InvalidComposeSender();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(
        address _seth,
        address _ethOft,
        address _lzEndpoint,
        address _orchestrator
    ) MintBurnOFTAdapter(_seth, IMintableBurnable(_seth), _lzEndpoint, _orchestrator) {
        if (_seth == address(0) || _ethOft == address(0)) revert InvalidAddress();
        seth = _seth;
        ethOft = _ethOft;
    }

    /// @notice Receive ETH from ethOft; hold until lzCompose tags it with transferId
    receive() external payable {
        if (msg.sender != ethOft) revert DirectDepositsDisabled();
        // ETH stays in adapter; lzCompose will record ethQueue[transferId]
    }

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    /// @notice Add a new SETHAdapter address for a destination chain
    /// @dev Each dstChain SETHAdapter relays ETH collateral from the other side of cross-chain transfers
    /// to maintain 1:100 collateralization on the chain's SETH contract.
    function addSethAdapter(uint32 _eid, address _adapter) external onlyOwner {
        sethAdapters[_eid] = _adapter;
    }

    // --------------------------------------------
    //  Quote Fee
    // --------------------------------------------

    /**
     * @notice Returns combined LayerZero fee (SETH message + ETH collateral bridge)
     * @dev Read only. Actual fee is deducted automatically from _send since ETH collateral is being moved by default.
     */
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view override returns (MessagingFee memory) {
        address dstAdapter = sethAdapters[_sendParam.dstEid];
        if (dstAdapter == address(0)) revert SethAdapterNotSet(_sendParam.dstEid);

        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        bytes memory composeForQuote = abi.encode(uint256(0));

        (MessagingFee memory ethFee, MessagingFee memory sethFee, ) =
            _quoteSendFees(_sendParam, amountSentLD, composeForQuote, dstAdapter, _payInLzToken);

        return MessagingFee({ nativeFee: sethFee.nativeFee + ethFee.nativeFee, lzTokenFee: sethFee.lzTokenFee + ethFee.lzTokenFee });
    }

    // --------------------------------------------
    //  Send Cross-Chain
    // --------------------------------------------

    /**
     * @notice Executes collateralized cross-chain SETH transfer. Fees deducted from underlying ETH collateral (not msg.value).
     * @dev MessagingFee is required as part of the IOFT interface, but the actual value is computed inside the _send function
     * because cross-chain SETH transfers also move underlying ETH collateral. LayerZero fees are deducted automatically from
     * the collateral balance. As a result, you can pass any value through as MessagingFee, such as MessagingFee(0, 0), or use
     * the quote provided by quoteSend.
     */
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable override returns (MessagingReceipt memory, OFTReceipt memory) {
        return _send(_sendParam, _fee, _refundAddress);
    }

    function _send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) internal virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        address dstAdapter = sethAdapters[_sendParam.dstEid];
        if (dstAdapter == address(0)) revert SethAdapterNotSet(_sendParam.dstEid);

        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        uint256 transferId = ++transferIdCounter;
        bytes memory transferIdPayload = abi.encode(transferId);

        // ─── Phase 1: Quote ─────────────────────────────────────────────────────
        (MessagingFee memory ethFee, , uint256 amountReceivedLD) =
            _quoteSendFees(_sendParam, amountSentLD, transferIdPayload, dstAdapter, false);

        if (amountReceivedLD < _sendParam.minAmountLD) revert IOFT.SlippageExceeded(amountReceivedLD, _sendParam.minAmountLD);

        // ─── Phase 2: Execute ───────────────────────────────────────────────────
        minterBurner.burn(msg.sender, amountSentLD);
        ISETH(seth).releaseCollateral(amountSentLD);

        uint256 ethAmount = amountReceivedLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParam = _buildEthSendParam(_sendParam, dstAdapter, ethAmount, transferIdPayload);
        IOFT(ethOft).send{value: ethAmount + ethFee.nativeFee}(ethParam, ethFee, _refundAddress);

        SendParam memory sethParam = _buildSethSendParam(_sendParam, amountReceivedLD, transferIdPayload);
        (bytes memory message, bytes memory options) = _buildMsgAndOptionsMemory(sethParam, amountReceivedLD, _sendParam.extraOptions);
        MessagingFee memory sethFee = _quote(_sendParam.dstEid, message, options, false);

        msgReceipt = _lzSend(_sendParam.dstEid, message, options, sethFee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }

    // --------------------------------------------
    //  Internal
    // --------------------------------------------

    /**
     * @notice Quotes ETH and SETH LayerZero fees, computes amountReceivedLD after fee deduction
     * @dev Uses amountSentLD for quotes; fee impact on message size is negligible. composeMsg can be abi.encode(0) for quoteSend.
     */
    function _quoteSendFees(
        SendParam calldata _sendParam,
        uint256 amountSentLD,
        bytes memory composeMsg,
        address dstAdapter,
        bool _payInLzToken
    ) internal view returns (MessagingFee memory ethFee, MessagingFee memory sethFee, uint256 amountReceivedLD) {
        uint256 ethAmountForQuote = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParamForQuote = _buildEthSendParam(_sendParam, dstAdapter, ethAmountForQuote, composeMsg);
        ethFee = IOFT(ethOft).quoteSend(ethParamForQuote, false);

        SendParam memory sethParamApprox = _buildSethSendParam(_sendParam, amountSentLD, composeMsg);
        (bytes memory messageApprox, bytes memory optionsApprox) =
            _buildMsgAndOptionsMemory(sethParamApprox, amountSentLD, _sendParam.extraOptions);
        sethFee = _quote(_sendParam.dstEid, messageApprox, optionsApprox, _payInLzToken);

        uint256 totalFees = sethFee.nativeFee + ethFee.nativeFee;
        uint256 feeSethAmount = totalFees * ISETH(seth).EXCHANGE_RATE();
        amountReceivedLD = amountSentLD - feeSethAmount;
    }

    /// @notice Build SendParam for ETH OFT (collateral bridge to dstAdapter)
    function _buildEthSendParam(
        SendParam calldata _sendParam,
        address dstAdapter,
        uint256 ethAmount,
        bytes memory composeMsg
    ) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: _sendParam.dstEid,
            to: _addressToBytes32(dstAdapter),
            amountLD: ethAmount,
            minAmountLD: ethAmount,
            extraOptions: "",
            composeMsg: composeMsg,
            oftCmd: ""
        });
    }

    /// @notice Build SendParam for SETH message (user-facing OFT params with variable amount/composeMsg)
    function _buildSethSendParam(
        SendParam calldata _sendParam,
        uint256 amountLD,
        bytes memory composeMsg
    ) internal pure returns (SendParam memory) {
        return SendParam({
            dstEid: _sendParam.dstEid,
            to: _sendParam.to,
            amountLD: amountLD,
            minAmountLD: _sendParam.minAmountLD,
            extraOptions: _sendParam.extraOptions,
            composeMsg: composeMsg,
            oftCmd: _sendParam.oftCmd
        });
    }

    /// @notice Convert address to bytes32 for LayerZero data object
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /// @notice Build message and options from memory SendParam (parent's _buildMsgAndOptions requires calldata)
    /// @param _extraOptions Must be calldata for combineOptions; pass from original _sendParam when available
    function _buildMsgAndOptionsMemory(
        SendParam memory _sendParam,
        uint256 _amountLD,
        bytes calldata _extraOptions
    ) internal view returns (bytes memory message, bytes memory options) {
        bool hasCompose;
        (message, hasCompose) = OFTMsgCodec.encode(_sendParam.to, _toSD(_amountLD), _sendParam.composeMsg);
        uint16 msgType = hasCompose ? SEND_AND_CALL : SEND;
        options = combineOptions(_sendParam.dstEid, msgType, _extraOptions);
        address inspector = msgInspector;
        if (inspector != address(0)) IOAppMsgInspector(inspector).inspect(message, options);
    }

    // --------------------------------------------
    //  Receive Cross-Chain ETH Collateral
    // --------------------------------------------

    /**
     * @notice Receives composeMsg from ethOft
     * @dev Records ethQueue[transferId] = amountLD; processes pending mint if SETH message arrived first.
     */
    function lzCompose(
        address _from,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override {
        if (msg.sender != address(endpoint)) revert InvalidComposeSender();
        if (_from != ethOft) revert InvalidComposeSender();

        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory rawCompose = OFTComposeMsgCodec.composeMsg(_message);

        uint256 transferId;
        assembly {
            transferId := mload(add(add(rawCompose, 32), 32))
        }

        ethQueue[transferId] = amountLD;
        _processPendingMint(transferId);
    }

    /**
     * @notice Relays collateral and processes SETH mint if SETH message has already arrived
     */
    function _processPendingMint(uint256 _transferId) internal {
        PendingMint memory pm = pendingMints[_transferId];
        if (pm.to == address(0)) return;

        uint256 ethAmount = ethQueue[_transferId];
        if (ethAmount == 0) return;

        delete ethQueue[_transferId];
        delete pendingMints[_transferId];

        ISETH(seth).receiveCollateral{value: ethAmount}();
        minterBurner.mint(pm.to, pm.amountLD);
    }

    // --------------------------------------------
    //  Receive Cross-Chain SETH
    // --------------------------------------------

    /**
     * @notice Override: extracts transferId from composeMsg
     * @dev Reads ethQueue[transferId] if ETH arrived first and mints; otherwise records pendingMints[transferId] for later.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal virtual override {
        if (!OFTMsgCodec.isComposed(_message)) revert InvalidComposeSender();

        address toAddress = OFTMsgCodec.bytes32ToAddress(OFTMsgCodec.sendTo(_message));
        uint256 amountReceivedLD = _toLD(OFTMsgCodec.amountSD(_message));
        bytes memory rawCompose = OFTMsgCodec.composeMsg(_message);

        uint256 transferId;
        assembly {
            transferId := mload(add(add(rawCompose, 32), 32))
        }

        _creditTransferId = transferId;
        _credit(toAddress, amountReceivedLD, _origin.srcEid);

        _creditTransferId = 0; // WHY RESET TO ZERO?
        emit OFTReceived(_guid, _origin.srcEid, toAddress, amountReceivedLD);
    }

    /**
     * @notice Processes SETH mint and relays collateral if ethAmount has already arrived
     */
    function _credit(
        address _to,
        uint256 _amountLD,
        uint32 /* _srcEid */
    ) internal virtual override returns (uint256) {
        if (_to == address(0)) _to = address(0xdead); // WHY SPECIFY DEAD ADDRESS - SHOULDN'T THIS ALWAYS BE A REAL ADDRESS?

        uint256 transferId = _creditTransferId;
        uint256 ethAmount = _amountLD / ISETH(seth).EXCHANGE_RATE();

        if (ethQueue[transferId] > 0) {
            delete ethQueue[transferId];
            ISETH(seth).receiveCollateral{value: ethAmount}();
            minterBurner.mint(_to, _amountLD);
        } else {
            pendingMints[transferId] = PendingMint({ to: _to, amountLD: _amountLD });
        }

        return _amountLD;
    }
}