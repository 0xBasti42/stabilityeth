// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";
import { IOFT, SendParam, MessagingFee, OFTReceipt } from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";

interface ISETH {
    function EXCHANGE_RATE() external view returns (uint256);
    function releaseCollateralForBridge(uint256 sethAmount) external;
}

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which handles cross-chain collateral flows
 */
contract SETHAdapter is MintBurnOFTAdapter {
    address public seth;
    address public ethOft;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    error InvalidAddress();
    error InsufficientFee();

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

    // --------------------------------------------
    //  Quote Cross-Chain
    // --------------------------------------------

    function quoteSend(SendParam calldata _sendParam, bool _payInLzToken) external view override returns (MessagingFee memory) {
        MessagingFee memory sethFee = super.quoteSend(_sendParam, _payInLzToken);
        (uint256 amountSentLD, ) = _debitView(_sendParam.amountLD, _sendParam.minAmountLD, _sendParam.dstEid);
        uint256 ethAmount = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        SendParam memory ethParam = SendParam({
            dstEid: _sendParam.dstEid,
            to: _sendParam.to,
            amountLD: ethAmount,
            minAmountLD: ethAmount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory ethFee = IOFT(ethOft).quoteSend(ethParam, false);
        return MessagingFee({ nativeFee: sethFee.nativeFee + ethFee.nativeFee, lzTokenFee: sethFee.lzTokenFee + ethFee.lzTokenFee });
    }

    // --------------------------------------------
    //  Send Cross-Chain
    // --------------------------------------------

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) external payable override returns (MessagingReceipt memory, OFTReceipt memory) {
        if (msg.value < _fee.nativeFee) revert InsufficientFee();
        return _send(_sendParam, _fee, _refundAddress);
    }

    function _send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    ) internal virtual override returns (MessagingReceipt memory msgReceipt, OFTReceipt memory oftReceipt) {
        // 1. Debit SETH amount
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            msg.sender,
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        // 2. Release ETH from SETH, bridge via ethOft
        uint256 ethAmount = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        ISETH(seth).releaseCollateralForBridge(amountSentLD);

        SendParam memory ethParam = SendParam({
            dstEid: _sendParam.dstEid,
            to: _sendParam.to,
            amountLD: ethAmount,
            minAmountLD: ethAmount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
        MessagingFee memory ethFee = IOFT(ethOft).quoteSend(ethParam, false);
        IOFT(ethOft).send{value: ethAmount + ethFee.nativeFee}(ethParam, ethFee, _refundAddress);

        // 3. Send SETH OFT message (peer mints on destination)
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(_sendParam, amountReceivedLD);
        MessagingFee memory sethFee = _quote(_sendParam.dstEid, message, options, false);
        msgReceipt = _lzSend(_sendParam.dstEid, message, options, sethFee, _refundAddress);
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);
        emit OFTSent(msgReceipt.guid, _sendParam.dstEid, msg.sender, amountSentLD, amountReceivedLD);
    }
}
