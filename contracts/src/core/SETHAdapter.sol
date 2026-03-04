// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";

interface ISETH {
    function EXCHANGE_RATE() external view returns (uint256);
    function releaseCollateralForBridge(uint256 sethAmount) external;
    function receiveCollateralFromBridge() external payable;
}

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which handles cross-chain collateral flows
 */
contract SETHAdapter is MintBurnOFTAdapter {
    address public seth;
    address public ethOft;

    // --------------------------------------------
    //  Config
    // --------------------------------------------
    
    // Spoke chain configs
    mapping(uint32 => address) public sethAdapters;  // eid => adapter address

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    error InvalidAddress();
    error DirectDepositsDisabled();
    error SethAdapterNotSet(uint32 eid);

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(
        address _seth,
        address _ethOft,
        address _lzEndpoint,
        address _owner
    ) MintBurnOFTAdapter(_seth, IMintableBurnable(_seth), _lzEndpoint, _owner) {
        if (_seth == address(0) || _ethOft == address(0)) revert InvalidAddress();
        seth = _seth;
        ethOft = _ethOft;
    }

    /// @notice Receive ETH from ethOft, forward to SETH as collateral
    receive() external payable {
        if (msg.sender != ethOft) revert DirectDepositsDisabled();
        ISETH(seth).receiveCollateralFromBridge{value: msg.value}();
    }

    // --------------------------------------------
    //  Upkeep
    // --------------------------------------------

    /// @notice Set SETHAdapter address for a destination chain (ETH collateral recipient)
    function addSethAdapter(uint32 _eid, address _adapter) external onlyOwner {
        sethAdapters[_eid] = _adapter;
    }

    // --------------------------------------------
    //  Helper
    // --------------------------------------------

    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    // --------------------------------------------
    //  Quote Cross-Chain
    // --------------------------------------------

    /// @notice Returns combined LayerZero fee (SETH message + ETH collateral bridge)
    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view override returns (MessagingFee memory) {
        address dstAdapter = sethAdapters[_sendParam.dstEid];
        if (dstAdapter == address(0)) revert SethAdapterNotSet(_sendParam.dstEid);

        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        uint256 ethAmountForQuote = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParam = SendParam({
            dstEid: _sendParam.dstEid,
            to: _addressToBytes32(dstAdapter),
            amountLD: ethAmountForQuote,
            minAmountLD: ethAmountForQuote,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory ethFee = IOFT(ethOft).quoteSend(ethParam, false);
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountSentLD);
        MessagingFee memory sethFee = _quote(_sendParam.dstEid, message, options, _payInLzToken);
        return MessagingFee({ nativeFee: sethFee.nativeFee + ethFee.nativeFee, lzTokenFee: sethFee.lzTokenFee + ethFee.lzTokenFee });
    }

    /// @notice Returns LayerZero fee in SETH terms (deducted from send amount)
    function quoteSendFeeInSeth(SendParam calldata _sendParam) external view returns (uint256 feeSethAmount) {
        MessagingFee memory fee = this.quoteSend(_sendParam, false);
        return fee.nativeFee * ISETH(seth).EXCHANGE_RATE();
    }

    /// @notice Returns amount received on destination (amount sent minus fee)
    function quoteAmountReceived(SendParam calldata _sendParam) external view returns (uint256 amountReceivedLD) {
        uint256 amountSentLD = _removeDust(_sendParam.amountLD);
        uint256 feeSethAmount = this.quoteSendFeeInSeth(_sendParam);
        return amountSentLD - feeSethAmount;
    }

    // --------------------------------------------
    //  Send Cross-Chain
    // --------------------------------------------

    /// @notice Executes collateralized cross-chain SETH transfer. Fees deducted from SETH (no ETH required).
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

        // Quote fees (use amountSentLD as approx; fee impact on quote is negligible)
        uint256 ethAmountForQuote = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParamForQuote = SendParam({
            dstEid: _sendParam.dstEid,
            to: _addressToBytes32(dstAdapter),
            amountLD: ethAmountForQuote,
            minAmountLD: ethAmountForQuote,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory ethFee = IOFT(ethOft).quoteSend(ethParamForQuote, false);
        (bytes memory messageApprox, bytes memory optionsApprox) = _buildMsgAndOptions(_sendParam, amountSentLD);
        MessagingFee memory sethFee = _quote(_sendParam.dstEid, messageApprox, optionsApprox, false);

        uint256 totalFees = sethFee.nativeFee + ethFee.nativeFee;
        uint256 feeSethAmount = totalFees * ISETH(seth).EXCHANGE_RATE();
        uint256 amountReceivedLD = amountSentLD - feeSethAmount;

        if (amountReceivedLD < _sendParam.minAmountLD) revert IOFT.SlippageExceeded(amountReceivedLD, _sendParam.minAmountLD);

        uint256 ethAmount = amountReceivedLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParam = SendParam({
            dstEid: _sendParam.dstEid,
            to: _addressToBytes32(dstAdapter),
            amountLD: ethAmount,
            minAmountLD: ethAmount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });

        // 1. Debit SETH (full amount; fee deducted from received)
        minterBurner.burn(msg.sender, amountSentLD);

        // 2. Release ETH from SETH, bridge via ethOft
        ISETH(seth).releaseCollateralForBridge(amountSentLD);
        IOFT(ethOft).send{value: ethAmount + ethFee.nativeFee}(ethParam, ethFee, _refundAddress);

        // 3. Send SETH OFT message (peer mints amountReceivedLD on destination)
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);
        sethFee = _quote(_sendParam.dstEid, message, options, false);
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, sethFee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);
        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }
}
