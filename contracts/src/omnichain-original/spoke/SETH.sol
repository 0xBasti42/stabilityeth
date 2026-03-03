// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";
import { ISETHAdapter } from "./interfaces/ISETHAdapter.sol";

/**
 * @title SETH | StabilityETH
 * @notice Minted and burned at a 100:1 ratio with ETH, provides Performance Based Returns (PBR)
 * @dev The PBR algorithm turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 */
contract SETH is ERC20Permit, IMintableBurnable {
    ISETHAdapter public adapter;

    // --------------------------------------------
    //  Config
    // --------------------------------------------
    
    uint256 public constant TRANSFER_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10000;
    
    // Fees accrued locally (in SETH terms, to be relayed to mainnet)
    uint256 public pendingFeeRelay;
    uint256 public constant FEE_RELAY_THRESHOLD = 1 ether; // 1 SETH = 0.01 ETH

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event FeeBurned(address indexed from, uint256 sethAmount);
    
    error Unauthorized();
    error InvalidAddress();
    error NoPendingFees();

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyAdapter() {
        if (msg.sender != address(adapter)) revert Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(address _adapter) ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {
        if (_adapter == address(0)) revert InvalidAddress();
        adapter = ISETHAdapter(_adapter);
    }

    // --------------------------------------------
    //  Override Collateral Exchange
    // --------------------------------------------

    /// @notice Relay ETH deposits
    receive() external payable {
        adapter.depositFor{value: msg.value}(msg.sender);
    }

    /// @notice Mint SETH at 100:1 ratio to ETH deposits
    function deposit() public payable {
        adapter.depositFor{value: msg.value}(msg.sender);
    }

    /// @notice Burn SETH and withdraw ETH at 100:1 ratio
    function withdraw(uint256 sethAmount) external {
        adapter.withdrawFor(msg.sender, sethAmount);
    }

    // --------------------------------------------
    //  Native Bridging
    // --------------------------------------------

    /// @notice IMintableBurnable handles native bridging from SETHAdapter (no collateral movements)
    function mint(address _to, uint256 _amount) external onlyAdapter returns (bool) {
        _mint(_to, _amount);
        return true;
    }

    /// @notice IMintableBurnable handles native bridging from SETHAdapter (no collateral movements)
    function burn(address _from, uint256 _amount) external onlyAdapter returns (bool) {
        _burn(_from, _amount);
        return true;
    }

    // --------------------------------------------
    //  Transient Fee Handling
    // --------------------------------------------

    function _update(address from, address to, uint256 value) internal virtual override {
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        uint256 fee = (value * TRANSFER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountAfterFee = value - fee;

        super._update(from, to, amountAfterFee);

        if (fee > 0) {
            super._update(from, address(0), fee);
            pendingFeeRelay += fee;
            emit FeeBurned(from, fee);
            // Remove auto-trigger here - adapter handles combined clearing
        }
    }

    // --------------------------------------------
    //  Fee Sweeping
    // --------------------------------------------

    function _ringfenceFees() internal {
        uint256 feeAmount = pendingFeeRelay;
        
        try adapter.ringfenceFees(feeAmount) returns (bool success) {
            if (success) {
                pendingFeeRelay = 0;
            }
        } catch {
            // Silent failure - fees remain pending
        }
    }

    function sweepFees() external payable {
        if (pendingFeeRelay == 0) revert NoPendingFees();
        
        // Forward any ETH to adapter for gas
        if (msg.value > 0) {
            (bool sent, ) = address(adapter).call{value: msg.value}("");
            require(sent, "ETH transfer failed");
        }
        
        _ringfenceFees();
    }

    // --------------------------------------------
    //  External
    // --------------------------------------------

    function clearPendingFees() external onlyAdapter returns (uint256 amount) {
        amount = pendingFeeRelay;
        pendingFeeRelay = 0;
        emit FeesCleared(amount);
    }
}