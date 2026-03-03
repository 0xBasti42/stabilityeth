// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SETH - StabilityETH
 * @notice Minted and burned at a 100:1 ratio with ETH, provides Performance Based Returns (PBR)
 * @dev The PBR algorithm turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 */
contract SETH is ERC20Permit, ReentrancyGuard {
    address public immutable pbrTreasury;

    uint256 public constant EXCHANGE_RATE = 100;
    uint256 public constant TRANSFER_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10000;

    uint256 public accruedFees;
    uint256 public constant FEE_SWEEP_THRESHOLD = 0.01 ether;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event FeesAccrued(address indexed from, uint256 amountAdded, uint256 totalOutstanding);
    event FeeSwept(uint256 ethSwept, uint256 treasuryBalance);

    error InvalidTreasury();
    error EthTransferFailed();

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(address _pbrTreasury) ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {
        if (_pbrTreasury == address(0)) revert InvalidTreasury();
        pbrTreasury = _pbrTreasury;
    }

    // --------------------------------------------
    //  Exchange SETH for ETH collateral
    // --------------------------------------------

    /// @notice Relay ETH deposits
    receive() external payable {
        deposit();
    }

    /// @notice Mint SETH at 100:1 ratio to ETH deposits
    function deposit() public payable {
        _mint(msg.sender, msg.value * EXCHANGE_RATE);
    }

    /// @notice Burn SETH and withdraw ETH at 100:1 ratio
    function withdraw(uint256 sethAmount) external nonReentrant {
        _burn(msg.sender, sethAmount);
        
        (bool success, ) = msg.sender.call{value: sethAmount / EXCHANGE_RATE}("");
        if (!success) revert EthTransferFailed();
    }

    // --------------------------------------------
    //  Release ETH for Performance Based Returns
    // --------------------------------------------

    /// @dev Override _update to apply fee on transfers (not mints/burns)
    function _update(address from, address to, uint256 value) internal virtual override {
        // Mint or burn: no fee
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Calculate fee
        uint256 fee = (value * TRANSFER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountAfterFee = value - fee;

        // Transfer net amount of SETH to recipient
        super._update(from, to, amountAfterFee);
        
        // Release underlying ETH collateral for fee amount
        if (fee > 0) {
            // Burn fee value of SETH and ringfence ETH collateral
            super._update(from, address(0), fee);
            uint256 ethFee = fee / EXCHANGE_RATE;
            accruedFees += ethFee;
            
            // Fee denominated in ETH
            emit FeesAccrued(from, ethFee, accruedFees);
            
            // Sweep ETH to PBRTreasury when accruedFees >= 0.01 ether
            if (accruedFees >= FEE_SWEEP_THRESHOLD) {
                _sweepFees();
            }
        }
    }

    /// @dev Internal sweep without reentrancy check (called from _update)
    function _sweepFees() internal {
        uint256 ethAmount = accruedFees;
        if (ethAmount == 0) return;
        
        accruedFees = 0;
        
        (bool success, ) = pbrTreasury.call{value: ethAmount}("");
        if (!success) revert EthTransferFailed();
        
        emit FeeSwept(ethAmount, pbrTreasury.balance);
    }

    /// @notice Manually sweep accrued fees to treasury (anyone can call)
    function sweepFees() external nonReentrant {
        _sweepFees();
    }

    // --------------------------------------------
    //  Check contract balances
    // --------------------------------------------

    /// @notice Get the ETH collateral backing outstanding SETH tokens
    function sethSupply() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice Get the ETH collateral backing outstanding SETH tokens
    function ethCollateral() external view returns (uint256) {
        return address(this).balance - accruedFees;
    }

    /// @notice Get the ETH value of currently accrued fees
    function accruedFeesInEth() external view returns (uint256) {
        return accruedFees;
    }

    // --------------------------------------------
    //  Check ETH:SETH collateralization
    // --------------------------------------------

    /// @notice Check if the 1:100 collateral ratio is maintained
    function isFullyBacked() external view returns (bool fullyBacked, uint256 collateralRatioBps) {
        uint256 supply = totalSupply();
        
        if (supply == 0) {
            return (true, BPS_DENOMINATOR); // 100% backed if no supply
        }
        
        uint256 collateral = address(this).balance - accruedFees;
        
        collateralRatioBps = (collateral * EXCHANGE_RATE * BPS_DENOMINATOR) / supply;
        fullyBacked = collateralRatioBps >= BPS_DENOMINATOR;
    }
}