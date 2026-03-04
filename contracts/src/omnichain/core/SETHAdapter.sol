// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which handles cross-chain collateral flows
 */
contract SETHAdapter is MintBurnOFTAdapter {
    address public seth;
    address public ethOft;

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(
        address _seth,
        address _ethOft,
        address _lzEndpoint,
        address _owner
    ) MintBurnOFTAdapter(_seth, IMintableBurnable(_seth), _lzEndpoint, _owner) {
        seth = _seth;
        ethOft = _ethOft;
    }

    // --------------------------------------------
    //  SETH Transfer
    // --------------------------------------------

    function _send(...) internal virtual override returns (...) {
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(msg.sender, ...);
        
        uint256 ethAmount = amountSentLD / ISETH(seth).EXCHANGE_RATE();
        ISETH(seth).releaseCollateralForBridge(amountSentLD);
        
        SendParam memory ethParam = SendParam({
            dstEid: _sendParam.dstEid,
            to: _sendParam.to,           // recipient on dst chain
            amountLD: ethAmount,
            minAmountLD: ethAmount,
            ...
        });
        MessagingFee memory ethFee = IOFT(ethOft).quoteSend(ethParam, false);
        IOFT(ethOft).send{value: ethAmount + ethFee.nativeFee}(ethParam, ethFee, msg.sender);
        
        msgReceipt = _lzSend(...);
        return (msgReceipt, oftReceipt);
    }

    // --------------------------------------------
    //  Collateral Transfer
    // --------------------------------------------
}