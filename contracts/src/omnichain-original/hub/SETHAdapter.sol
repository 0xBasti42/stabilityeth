// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";

struct Origin {
    uint32 srcEid;      // Source endpoint ID (chain)
    bytes32 sender;     // Sender address (as bytes32)
    uint64 nonce;       // Message nonce
}

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which interfaces with lzEndpoint contracts
 */
contract SETHAdapter is MintBurnOFTAdapter, IStargateReceiver {
    ISETH public seth;
    IPBRTreasury public pbrTreasury;
    IStargateRouter public stargateRouter;

    // --------------------------------------------
    //  Config
    // --------------------------------------------
    
    // Spoke chain configs
    mapping(uint32 => address) public spokeAdapters;  // eid => adapter address
    
    // Message types for custom LZ messages
    uint8 constant MSG_TYPE_FEE_NOTIFY = 0;
    uint8 constant MSG_TYPE_DEPOSIT_REQUEST = 1;
    uint8 constant MSG_TYPE_WITHDRAW_REQUEST = 2;
    uint8 constant MSG_TYPE_COMBINED_CLEARING = 3;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event OmnichainRequest(uint8 msgType, uint256 timestamp);

    error UnauthorizedSpoke(uint32 srcEid, bytes32 sender);
    error SpokeNotConfigured(uint32 srcEid);

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    /// @notice Validate that a LayerZero message comes from a registered spoke adapter
    function _validateSpokeOrigin(Origin calldata _origin) internal view {
        bytes32 expectedSender = spokeAdapters[_origin.srcEid];
        
        if (expectedSender == bytes32(0)) {
            revert SpokeNotConfigured(_origin.srcEid);
        }
        
        if (_origin.sender != expectedSender) {
            revert UnauthorizedSpoke(_origin.srcEid, _origin.sender);
        }
    }

    /// @notice Convert address to bytes32 (for LZ compatibility)
    function _addressToBytes32(address _addr) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(_addr)));
    }

    /// @notice Convert bytes32 to address
    function _bytes32ToAddress(bytes32 _b) internal pure returns (address) {
        return address(uint160(uint256(_b)));
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------
    
    constructor(
        address _seth,
        IMintableBurnable _minterBurner,
        address _lzEndpoint,
        address _owner,
        address _stargateRouter,
        address _pbrTreasury
    ) MintBurnOFTAdapter(_seth, _minterBurner, _lzEndpoint, _owner) {
        seth = ISETH(_seth);
        stargateRouter = IStargateRouter(_stargateRouter);
        pbrTreasury = IPBRTreasury(_pbrTreasury);
    }

    receive() external payable {
        if (
            msg.sender != address(seth) &&          // Handle omnichain withdrawals
            msg.sender != address(stargateRouter)   // Handle omnichain deposits
        ) revert InvalidAddress();
    }

    // --------------------------------------------
    //  Native Bridging
    // --------------------------------------------

    // Not sure how this works with MintBurnOFTAdapter
    // - Should make use of minterBurner to update SETH supply on srcChain/dstChain
    // - Doesn't need to transfer collateral at all
    // - Just needs to interface with other SETHAdapter contracts to update local balances

    // --------------------------------------------
    //  Omnichain Messages
    // --------------------------------------------

    /// @notice Stargate callback for deposits
    function sgReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        address _token,
        uint256 _amountLD,
        bytes memory _payload
    ) external override {
        require(msg.sender == address(stargateRouter), "Only Stargate");
        require(_token == address(0), "Only Ether");
        
        // Deposit full batched amount
        seth.deposit{value: _amountLD}();
        
        // If payload contains fee info, process it
        if (_payload.length > 0) {
            (uint8 msgType, uint256 collateralAmount, uint256 feeAmount) = 
                abi.decode(_payload, (uint8, uint256, uint256));
            
            if (msgType == MSG_TYPE_COMBINED_CLEARING && feeAmount > 0) {
                seth.ringfenceFees(feeAmount);
            }
        }

        emit OmnichainRequest(MSG_TYPE_DEPOSIT_REQUEST, block.timestamp);
    }

    /// @notice LayerZero callback for fees and withdrawals
    function _lzReceive(
        Origin calldata _origin,
        bytes32 _guid,
        bytes calldata _message,
        address _executor,
        bytes calldata _extraData
    ) internal override {
        _validateSpokeOrigin(_origin);
        
        uint8 msgType = uint8(_message[0]);

        if (msgType == MSG_TYPE_WITHDRAW_REQUEST) {
            _withdrawFor(_origin.srcEid, _message);
        } else if (msgType == MSG_TYPE_FEE_NOTIFY) {
            _ringfenceFees(_origin.srcEid, _message);
        } else if (msgType == MSG_TYPE_COMBINED_CLEARING) {
            _processCombinedClearing(_origin.srcEid, _message);
        }

        emit OmnichainRequest(msgType, block.timestamp);
    }

    // --------------------------------------------
    //  Derived Actions
    // --------------------------------------------

    function _depositFor(address recipient, uint256 ethAmount) internal {
        if (msg.value == 0) revert InsufficientValue();
        
        // ETH collateral has been sent to this contract already
        seth.deposit{value: ethAmount}();
        
        emit DepositInitiated(recipient, ethAmount, sethAmount);
    }

    function _withdrawFor(uint32 srcEid, bytes calldata _message) internal {
        (address recipient, uint256 sethAmount, uint32 srcEid) = 
            abi.decode(_message[1:], (address, uint256, uint32));

        // Burns SETH and recovers ETH collateral
        seth.withdraw(sethAmount);
        
        // Returns ETH collateral to recipient
        uint256 ethAmount = sethAmount / EXCHANGE_RATE;
        _sendCollateral(srcEid, recipient, ethAmount);

        emit WithdrawInitiated(recipient, sethAmount);
    }

    // Handle fee notification from spoke
    function _ringfenceFees(uint32 srcEid, bytes calldata _message) internal {
        uint256 sethAmount = abi.decode(_message[1:], (uint256));
        
        // Tell SETH to burn from our balance and ringfence ETH
        seth.ringfenceFees(sethAmount);
    }

    function _processCombinedClearing(uint32 srcEid, bytes calldata _message) internal {
        (uint256 collateralAmount, uint256 feeAmount) = 
            abi.decode(_message[1:], (uint256, uint256));
        
        // ETH collateral arrives via Stargate sgReceive
        // This message just notifies about fees
        
        if (feeAmount > 0) {
            seth.ringfenceFees(feeAmount);
        }
    }

    // --------------------------------------------
    //  Collateral Transfers
    // --------------------------------------------

    function _sendCollateral(uint32 eid, address recipient, uint256 amount) internal {
        // Stargate bridge call
    }

    // --------------------------------------------
    //  Admin Functions
    // --------------------------------------------

    /// @notice Register a spoke adapter for a specific chain
    /// @param _eid The LayerZero endpoint ID for the spoke chain
    /// @param _spokeAdapter The spoke SETHAdapter address
    function setSpokeAdapter(uint32 _eid, address _spokeAdapter) external onlyOwner {
        spokeAdapters[_eid] = _addressToBytes32(_spokeAdapter);
        emit SpokeAdapterSet(_eid, _spokeAdapter);
    }

    /// @notice Remove a spoke adapter
    function removeSpokeAdapter(uint32 _eid) external onlyOwner {
        delete spokeAdapters[_eid];
        emit SpokeAdapterRemoved(_eid);
    }
}