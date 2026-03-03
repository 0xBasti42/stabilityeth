// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { MintBurnOFTAdapter } from "@layerzerolabs/oft-evm/contracts/MintBurnOFTAdapter.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
// Import Stargate interface for ETH bridging

/**
 * @title SETHAdapter | StabilityETH
 * @notice LayerZero OFT wrapper for SETH which interfaces with lzEndpoint addresses
 */
contract SETHAdapter is MintBurnOFTAdapter {
    using OptionsBuilder for bytes;

    uint32 public hubEid;
    address public mainnetAdapter;
    address public stargateRouter;

    uint8 constant MSG_TYPE_FEE_NOTIFY = 0;
    uint8 constant MSG_TYPE_DEPOSIT_REQUEST = 1;
    uint8 constant MSG_TYPE_WITHDRAW_REQUEST = 2;

    uint256 public constant GAS_RESERVE_THRESHOLD = 0.01 ether;

    uint256 public constant EXCHANGE_RATE = 100;

    uint256 public pendingCollateral;  // ETH waiting to be bridged
    uint256 public constant COLLATERAL_BRIDGE_THRESHOLD = 1 ether;

    mapping(address => uint256) public depositCredits;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event DepositInitiated(address indexed user, uint256 ethAmount, uint256 sethAmount);
    event WithdrawInitiated(address indexed user, uint256 sethAmount);
    event FeesRelayed(uint256 sethBurned, uint256 ethEquivalent);

    error Unauthorized();
    error InvalidAddress();
    error InsufficientValue();

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlySeth() {
        if (msg.sender != address(innerToken)) revert Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(
        address _seth,
        IMintableBurnable _minterBurner, // Can be _seth if SETH implements IMintableBurnable
        address _lzEndpoint,
        address _owner,
        address _stargateRouter,
        uint32 _hubEid,
        address _mainnetAdapter
    ) MintBurnOFTAdapter(_seth, _minterBurner, _lzEndpoint, _owner) Ownable(_owner) {
        stargateRouter = _stargateRouter;
        mainnetAdapter = _mainnetAdapter;
        hubEid = _hubEid;
    }

    receive() external payable {
        if (msg.sender != address(innerToken) && msg.sender != stargateRouter) {
            revert Unauthorized();
        }
    }

    // --------------------------------------------
    //  Native Bridging
    // --------------------------------------------

    // Not sure how this works with MintBurnOFTAdapter
    // - Should make use of minterBurner to update SETH supply on srcChain/dstChain
    // - Doesn't need to transfer collateral at all
    // - Just needs to interface with other SETHAdapter contracts to update local balances

    // --------------------------------------------
    //  Collateral Requests
    // --------------------------------------------

    function depositFor(address recipient) public payable onlySeth {
        _depositFor(recipient);
    }

    function withdrawFor(address recipient, uint256 sethAmount) external onlySeth {
        _withdrawFor(recipient, sethAmount);
    }

    function ringfenceFees(uint256 sethBurned) external onlySeth returns (bool) {
        return _ringfenceFees(sethBurned);
    }

    // --------------------------------------------
    //  Collateral Transfers
    // --------------------------------------------

    function _depositFor(address recipient) internal {
        if (msg.value == 0) revert InsufficientValue();
        uint256 preBalance = address(this).balance - msg.value;

        // Calculate gas contribution (existing logic)
        uint256 gasContribution = 0;
        if (preBalance < GAS_RESERVE_THRESHOLD) {
            gasContribution = _getGasContribution(msg.value, preBalance);
        }
        
        uint256 depositAmount = msg.value - gasContribution;
        uint256 sethAmount = depositAmount * EXCHANGE_RATE;
        
        // Mint SETH immediately to user (optimistic minting)
        minterBurner.mint(recipient, sethAmount);
        
        // Stack collateral locally instead of bridging
        pendingCollateral += depositAmount;
        
        emit DepositInitiated(recipient, depositAmount, sethAmount);
        
        // Trigger clearing if threshold reached
        if (pendingCollateral >= COLLATERAL_BRIDGE_THRESHOLD) {
            _clearToMainnet();
        }
    }

    function _withdrawFor(address recipient, uint256 sethAmount) internal {
        if (sethAmount == 0) revert InsufficientValue();

        minterBurner.burn(recipient, sethAmount);
        
        uint256 ethAmount = sethAmount / EXCHANGE_RATE;
        _requestCollateral(recipient, ethAmount); // Recipient receives ETH collateral from SETHAdapter on mainnet
        
        emit WithdrawInitiated(recipient, sethAmount);
    }

    // --------------------------------------------
    //  Dynamic Gas
    // --------------------------------------------

    function _getGasContribution(uint256 depositValue, uint256 preBalance) internal pure returns (uint256) {
        uint256 deficit = GAS_RESERVE_THRESHOLD - preBalance;
        
        if (depositValue >= 1 ether) {
            // Large deposits: Returns deficit (max 0.01 ether)
            return deficit;
        } else if (depositValue >= 0.1 ether) {
            // Medium deposits: Maximum 1% contribution, capped at deficit
            uint256 contribution = depositValue / 100;  // max. 1%
            return contribution > deficit ? deficit : contribution;
        } else if (depositValue >= 0.01 ether) {
            // Small deposits: Maximum 1% contribution, capped at deficit
            uint256 contribution = depositValue / 100;
            return contribution > deficit ? deficit : contribution;
        }
        
        return 0;   // No contribution for small deposits (<0.01 ETH)
    }

    // --------------------------------------------
    //  Mainnet Messages
    // --------------------------------------------

    // Internal: Bridge ETH via Stargate
    function _sendCollateral(uint256 amount) internal {
        // TODO: Implement Stargate ETH bridging
        // IStargateRouter(stargateRouter).swap{value: amount}(...)
    }

    // Internal: Request ETH release from mainnet
    function _requestCollateral(address recipient, uint256 amount) internal {
        // TODO: Send LayerZero message to mainnet adapter
        // This could be a custom message type alongside OFT transfers
    }

    // --------------------------------------------
    //  Collateral Transfer
    // --------------------------------------------

    function _clearToMainnet() internal {
        uint256 collateralAmount = pendingCollateral;
        uint256 feeAmount = ISETH(address(innerToken)).pendingFeeRelay();
        
        if (collateralAmount == 0 && feeAmount == 0) return;
        
        // Build the combined payload for hub
        bytes memory payload = abi.encode(
            MSG_TYPE_COMBINED_CLEARING,  // New message type = 3
            collateralAmount,            // ETH being bridged
            feeAmount                    // SETH fees to ringfence
        );
        
        // Quote LayerZero fee for the message
        bytes memory options = OptionsBuilder.newOptions()
            .addExecutorLzReceiveOption(300_000, 0);  // Higher gas for combined op
        MessagingFee memory lzFee = _quote(hubEid, payload, options, false);
        
        // Check we have enough gas to execute
        uint256 totalGasNeeded = lzFee.nativeFee;
        if (address(this).balance < collateralAmount + totalGasNeeded) {
            // Not enough gas - abort silently, will retry on next deposit
            return;
        }
        
        // Reset state BEFORE external calls (CEI pattern)
        pendingCollateral = 0;
        if (feeAmount > 0) {
            ISETH(address(innerToken)).clearPendingFees();  // New function needed in spoke SETH
        }
        
        // Send ETH collateral via Stargate (carries the payload)
        _sendCollateralWithPayload(collateralAmount, payload);
        
        // OR: If Stargate doesn't support payload, send separately:
        // _sendCollateral(collateralAmount);
        // _lzSend(hubEid, payload, options, lzFee, payable(address(this)));
        
        emit ClearingInitiated(collateralAmount, feeAmount);
    }

    /// @notice Manual clearing trigger (anyone can call with ETH for gas)
    function clearToMainnet() external payable {
        _clearToMainnet();
    }
}