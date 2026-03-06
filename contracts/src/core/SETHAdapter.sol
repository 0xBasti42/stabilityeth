// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";
import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";
import { Pausable } from "@openzeppelin-v5/contracts/utils/Pausable.sol";
import { ReentrancyGuardTransient } from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";
import { ILayerZeroComposer } from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroComposer.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";
import { IOAppMsgInspector } from "@layerzerolabs/oapp-evm/contracts/oapp/interfaces/IOAppMsgInspector.sol";
import { MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppSender.sol";
import { OFTComposeMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTComposeMsgCodec.sol";
import { OFTMsgCodec } from "@layerzerolabs/oft-evm/contracts/libs/OFTMsgCodec.sol";
import { Origin } from "@layerzerolabs/oapp-evm/contracts/oapp/OAppReceiver.sol";

interface ISETH {
    function EXCHANGE_RATE() external view returns (uint256);
    function releaseCollateral(uint256 sethAmount) external;
    function receiveCollateral() external payable;
}

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which handles cross-chain collateral flows.
 * @dev Uses (srcEid, transferId) composite key to match ETH and SETH messages; only mints when ETH has arrived.
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @custom:security-contact security@islalabs.co
 */
contract SETHAdapter is MintBurnOFTAdapter, RateLimiter, Pausable, ReentrancyGuardTransient, ILayerZeroComposer {
    address public immutable SETH;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice ETH OFT address on srcChain
    address public immutable ETH_OFT;

    /// @notice SETHAdapter addresses on dstChains
    mapping(uint32 => address) public sethAdapters;

    // ─── Minimum transfer ───────────────────────────────────────────────────

    /// @notice Minimum transfer amount in SETH wei (0 = disabled)
    uint256 public minTransferAmountLD;

    /// @dev Fixed-point unit for 18-decimal math (1e18 = 1 SETH)
    uint256 private constant WAD = 1e18;

    /// @dev Default minimum transfer: 0.1 SETH (WAD / 10)
    uint256 private constant MIN_TRANSFER_DEFAULT = WAD / 10;

    // ─── Liquidity coordination ─────────────────────────────────────────────

    /// @notice Monotonic transfer ID for correlating ETH and SETH messages
    uint256 public transferIdCounter;

    /// @notice ETH received for (srcEid, transferId) from ETH_OFT lzCompose
    mapping(uint32 srcEid => mapping(uint256 transferId => uint256)) public ethQueue;

    /// @notice Pending mints when SETH arrives before ETH
    struct PendingMint {
        address to;
        uint256 amountLD;
    }
    mapping(uint32 srcEid => mapping(uint256 transferId => PendingMint)) public pendingMints;

    /// @dev Set by _lzReceive before calling _credit; read by _credit for (srcEid, transferId)-based matching.
    uint256 private transient _creditTransferId;
    uint32 private transient _creditSrcEid;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event NewChainAdded(uint32 indexed eid, address adapter);
    event MinTransferAmountSet(uint256 oldMin, uint256 newMin);

    error InvalidAddress();
    error InvalidEid();
    error InvalidRecipient();
    error InvalidAmount();
    error DirectDepositsDisabled();
    error SethAdapterNotSet(uint32 eid);
    error AdapterAlreadySet(uint32 eid);
    error InvalidComposeSender();
    error InvalidRateLimitWindow();
    error AmountBelowMinimum();

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
        SETH = _seth;
        ETH_OFT = _ethOft;

        minTransferAmountLD = MIN_TRANSFER_DEFAULT;
    }

    /// @notice Receive ETH from ETH_OFT; hold until lzCompose tags it with transferId
    receive() external payable {
        if (msg.sender != ETH_OFT) revert DirectDepositsDisabled();
        // ETH stays in adapter; lzCompose will record ethQueue[srcEid][transferId]
    }

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    /// @notice Add a new SETHAdapter address for a destination chain with the default rate limit
    /// @dev Each dstChain SETHAdapter relays ETH collateral from the other side of cross-chain transfers
    /// to maintain 1:100 collateralization on the chain's SETH contract.
    function addSethAdapter(
        uint32 _eid,
        address _adapter,
        uint192 _limit,
        uint64 _window
    ) external onlyOwner {
        if (_eid == 0) revert InvalidEid();
        if (_adapter == address(0)) revert InvalidAddress();
        if (sethAdapters[_eid] != address(0)) revert AdapterAlreadySet(_eid);
        if (_window < 12) revert InvalidRateLimitWindow();

        sethAdapters[_eid] = _adapter;
        emit NewChainAdded(_eid, _adapter);

        RateLimiter.RateLimitConfig[] memory configs = new RateLimiter.RateLimitConfig[](1);
        configs[0] = RateLimiter.RateLimitConfig({ dstEid: _eid, limit: _limit, window: _window });
        _setRateLimits(configs);
    }

    // --------------------------------------------
    //  Quote Fee
    // --------------------------------------------

    /**
     * @notice Returns combined LayerZero fee (SETH message + ETH collateral bridge)
     * @dev Read only. Actual fee is deducted automatically from _send since ETH collateral is being moved by default.
     */
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view override returns (MessagingFee memory) {
        if (_sendParam.to == bytes32(0)) revert InvalidRecipient();
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
    ) external payable override whenNotPaused nonReentrant returns (MessagingReceipt memory, OFTReceipt memory) {
        return _send(_sendParam, _fee, _refundAddress);
    }

    function _send(
        SendParam calldata _sendParam,
        MessagingFee calldata /* _fee */,
        address _refundAddress
    ) internal virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        if (_sendParam.to == bytes32(0)) revert InvalidRecipient();

        address dstAdapter = sethAdapters[_sendParam.dstEid];
        if (dstAdapter == address(0)) revert SethAdapterNotSet(_sendParam.dstEid);

        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        if (amountSentLD == 0) revert InvalidAmount();
        if (minTransferAmountLD > 0 && amountSentLD < minTransferAmountLD) revert AmountBelowMinimum();

        uint256 transferId = ++transferIdCounter;
        bytes memory transferIdPayload = abi.encode(transferId);

        // ─── Phase 1: Quote ─────────────────────────────────────────────────────
        (MessagingFee memory ethFee, , uint256 amountReceivedLD) =
            _quoteSendFees(_sendParam, amountSentLD, transferIdPayload, dstAdapter, false);

        if (amountReceivedLD < _sendParam.minAmountLD) revert IOFT.SlippageExceeded(amountReceivedLD, _sendParam.minAmountLD);

        _outflow(_sendParam.dstEid, amountSentLD);

        // ─── Phase 2: Execute ───────────────────────────────────────────────────
        minterBurner.burn(msg.sender, amountSentLD);
        ISETH(SETH).releaseCollateral(amountSentLD);

        uint256 ethAmount = amountReceivedLD / ISETH(SETH).EXCHANGE_RATE();
        SendParam memory ethParam = _buildEthSendParam(_sendParam, dstAdapter, ethAmount, transferIdPayload);
        IOFT(ETH_OFT).send{value: ethAmount + ethFee.nativeFee}(ethParam, ethFee, _refundAddress);

        SendParam memory sethParam = _buildSethSendParam(_sendParam, amountReceivedLD, transferIdPayload);
        (bytes memory message, bytes memory options) = _buildMsgAndOptionsMemory(sethParam, amountReceivedLD, _sendParam.extraOptions);
        MessagingFee memory sethFee = _quote(_sendParam.dstEid, message, options, false);

        msgReceipt = _lzSend(_sendParam.dstEid, message, options, sethFee, _refundAddress);
        oftReceipt = OFTReceipt({ amountSentLD: amountSentLD, amountReceivedLD: amountReceivedLD });

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
        uint256 ethAmountForQuote = amountSentLD / ISETH(SETH).EXCHANGE_RATE();
        SendParam memory ethParamForQuote = _buildEthSendParam(_sendParam, dstAdapter, ethAmountForQuote, composeMsg);
        ethFee = IOFT(ETH_OFT).quoteSend(ethParamForQuote, false);

        SendParam memory sethParamApprox = _buildSethSendParam(_sendParam, amountSentLD, composeMsg);
        (bytes memory messageApprox, bytes memory optionsApprox) =
            _buildMsgAndOptionsMemory(sethParamApprox, amountSentLD, _sendParam.extraOptions);
        sethFee = _quote(_sendParam.dstEid, messageApprox, optionsApprox, _payInLzToken);

        uint256 totalFees = sethFee.nativeFee + ethFee.nativeFee;
        uint256 feeSethAmount = totalFees * ISETH(SETH).EXCHANGE_RATE();
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
     * @notice Receives composeMsg from ETH_OFT
     * @dev Records ethQueue[srcEid][transferId] = amountLD; processes pending mint if SETH message arrived first.
     *      srcEid from OFTComposeMsgCodec (set by ETH OFT from LayerZero origin) prevents cross-chain transferId collision.
     */
    function lzCompose(
        address _from,
        bytes32 /* _guid */,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) external payable override nonReentrant {
        if (msg.sender != address(endpoint)) revert InvalidComposeSender();
        if (_from != ETH_OFT) revert InvalidComposeSender();

        uint32 srcEid = OFTComposeMsgCodec.srcEid(_message);
        uint256 amountLD = OFTComposeMsgCodec.amountLD(_message);
        bytes memory rawCompose = OFTComposeMsgCodec.composeMsg(_message);

        uint256 transferId;
        assembly {
            transferId := mload(add(add(rawCompose, 32), 32))
        }

        ethQueue[srcEid][transferId] = amountLD;
        _processPendingMint(srcEid, transferId);
    }

    /**
     * @notice Relays collateral and processes SETH mint if SETH message has already arrived
     */
    function _processPendingMint(uint32 _srcEid, uint256 _transferId) internal {
        PendingMint memory pm = pendingMints[_srcEid][_transferId];
        if (pm.to == address(0)) return;

        uint256 ethAmount = ethQueue[_srcEid][_transferId];
        if (ethAmount == 0) return;

        delete ethQueue[_srcEid][_transferId];
        delete pendingMints[_srcEid][_transferId];

        ISETH(SETH).receiveCollateral{value: ethAmount}();
        minterBurner.mint(pm.to, pm.amountLD);
        _inflow(_srcEid, pm.amountLD);
    }

    // --------------------------------------------
    //  Receive Cross-Chain SETH
    // --------------------------------------------

    /**
     * @notice Override: extracts transferId from composeMsg
     * @dev Reads ethQueue[srcEid][transferId] if ETH arrived first and mints; otherwise records pendingMints[srcEid][transferId] for later.
     */
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address /* _executor */,
        bytes calldata /* _extraData */
    ) internal virtual override nonReentrant {
        if (!OFTMsgCodec.isComposed(_message)) revert InvalidComposeSender();

        address toAddress = OFTMsgCodec.bytes32ToAddress(OFTMsgCodec.sendTo(_message));
        uint256 amountReceivedLD = _toLD(OFTMsgCodec.amountSD(_message));
        bytes memory rawCompose = OFTMsgCodec.composeMsg(_message);

        uint256 transferId;
        assembly {
            transferId := mload(add(add(rawCompose, 32), 32))
        }

        _creditTransferId = transferId;
        _creditSrcEid = _origin.srcEid;
        _credit(toAddress, amountReceivedLD, _origin.srcEid);

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
        uint256 transferId = _creditTransferId;
        uint32 srcEid = _creditSrcEid;
        uint256 ethAmount = _amountLD / ISETH(SETH).EXCHANGE_RATE();

        if (ethQueue[srcEid][transferId] > 0) {
            delete ethQueue[srcEid][transferId];
            ISETH(SETH).receiveCollateral{value: ethAmount}();
            minterBurner.mint(_to, _amountLD);
            _inflow(srcEid, _amountLD);
        } else {
            pendingMints[srcEid][transferId] = PendingMint({ to: _to, amountLD: _amountLD });
        }

        return _amountLD;
    }

    // --------------------------------------------
    //  Admin
    // --------------------------------------------

    /// @notice Set rate limits per destination chain
    /// @dev Must be configured for each dstEid before sends are allowed. Use conservative limits initially.
    function setRateLimits(RateLimiter.RateLimitConfig[] calldata _rateLimitConfigs) external onlyOwner {
        _setRateLimits(_rateLimitConfigs);
    }

    /// @notice Reset rate limit in-flight amounts for given chains
    function resetRateLimits(uint32[] calldata _eids) external onlyOwner {
        _resetRateLimits(_eids);
    }

    /// @notice Pause outbound sends
    /// @dev Inbound transfers (lzCompose, _lzReceive) remain enabled so in-flight transfers can complete.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause outbound sends
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Set minimum transfer amount
    function setMinTransferAmount(uint256 _min) external onlyOwner {
        uint256 oldMin = minTransferAmountLD;
        minTransferAmountLD = _min;
        emit MinTransferAmountSet(oldMin, _min);
    }
}