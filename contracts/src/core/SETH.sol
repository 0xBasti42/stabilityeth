// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title SETH | StabilityETH
 * @notice Omnichain SETH is minted and burned at a 100:1 ratio with ETH; provides Performance Based Returns (PBR) to verified applications
 * @dev Turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 */
contract SETH is ERC20Permit, ReentrancyGuard {
    address public immutable sethAdapter;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice Maintains 1:100 collateralization between ETH and SETH
    uint256 public constant EXCHANGE_RATE = 100;

    /// @notice 0.3% fee-on-transfer which gets circulated to verified applications as Performance Based Returns (PBR)
    uint256 public constant TRANSFER_FEE_BPS = 30;

    /// @notice Standardized basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Ringfenced account keeping for fee-on-transfer; collected lazily during PBR distribution
    uint256 public accruedFees;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event FeesAccrued(address indexed from, uint256 amountAdded, uint256 totalOutstanding);

    error InvalidAddress();
    error Unauthorized();
    error EthTransferFailed();

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyAdapter() {
        if (msg.sender != sethAdapter) revert Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(address _adapter) ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {
        if (_adapter == address(0)) revert InvalidAddress();
        sethAdapter = _adapter;
    }

    // --------------------------------------------
    //  Collateral Exchange
    // --------------------------------------------

    /**
    * @notice Relays ETH deposits to deposit()
    */
    receive() external payable {
        deposit();
    }

    /**
    * @notice Mints SETH at 100:1 ratio to ETH deposits
    */
    function deposit() public payable {
        uint256 sethAmount = msg.value * EXCHANGE_RATE;

        _mint(msg.sender, sethAmount);
    }

    /**
    * @notice Burns SETH and withdraws ETH at 100:1 ratio
    */
    function withdraw(uint256 sethAmount) external nonReentrant {
        _burn(msg.sender, sethAmount);
        (bool success, ) = msg.sender.call{value: sethAmount / EXCHANGE_RATE}("");
        if (!success) revert EthTransferFailed();
    }

    // --------------------------------------------
    //  Cross-Chain Transfers
    // --------------------------------------------

    /**
    * @notice Burns SETH from account
    * @dev Function restricted to SETHAdapter only for debiting cross-chain transfers
    */
    function burn(address from, uint256 amount) external onlyAdapter returns (bool) {
        _burn(from, amount);
        return true;
    }

    /**
    * @notice Mints SETH to account
    * @dev Function restricted to SETHAdapter only for crediting cross-chain transfers
    */
    function mint(address to, uint256 amount) external onlyAdapter returns (bool) {
        _mint(to, amount);
        return true;
    }

    /**
    * @notice Releases ETH collateral for cross-chain SETH transfers
    * @dev Function restricted to SETHAdapter only; sends ethAmount to caller
    */
    function releaseCollateral(uint256 sethAmount) external onlyAdapter {
        uint256 ethAmount = sethAmount / EXCHANGE_RATE;
        (bool success, ) = msg.sender.call{value: ethAmount}("");
        if (!success) revert EthTransferFailed();
    }

    /**
    * @notice Receives ETH collateral from cross-chain SETH transfers
    * @dev Function restricted to SETHAdapter only; receives ETH amount without minting SETH equivalent
    */
    function receiveCollateral() external payable onlyAdapter { }

    // --------------------------------------------
    //  Fee Handling
    // --------------------------------------------

    /**
    * @notice Overrides _update to apply PBR fee on transfers
    * @dev Fee not applied to mints/burns, which covers deposit(), withdraw(), and cross-chain transfers
    */
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
        }
    }

    // --------------------------------------------
    //  View Functions
    // --------------------------------------------

    /// @notice Total SETH supply across all chains
    function chainSupply() external view returns (uint256) {
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
        
        uint256 collateral = address(this).balance;
        
        collateralRatioBps = (collateral * EXCHANGE_RATE * BPS_DENOMINATOR) / supply;
        fullyBacked = collateralRatioBps >= BPS_DENOMINATOR;
    }
}