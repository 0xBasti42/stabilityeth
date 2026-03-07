// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin-v5/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin-v5/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ReentrancyGuardTransient } from "@openzeppelin-v5/contracts/utils/ReentrancyGuardTransient.sol";

/**
 * @title SETH | StabilityETH
 * @notice Omnichain SETH is minted and burned at a 100:1 ratio with ETH; provides Performance Based Returns (PBR) to verified applications
 * @dev Turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @custom:security-contact security@islalabs.co
 */
contract SETH is ERC20, ERC20Permit, ReentrancyGuardTransient {
    address public immutable SETH_ADAPTER;

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
        if (msg.sender != SETH_ADAPTER) revert Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor(address _sethAdapter) ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {
        if (_sethAdapter == address(0)) revert InvalidAddress();
        SETH_ADAPTER = _sethAdapter;
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
     * @dev Rounds down to nearest multiple of EXCHANGE_RATE; dust stays with caller
     */
    function withdraw(uint256 sethAmount) external nonReentrant {
        // Round down to maintain 1:100 collateralization; dust stays with sender (up to 99 wei)
        uint256 amountToWithdraw = (sethAmount / EXCHANGE_RATE) * EXCHANGE_RATE;
        _burn(msg.sender, amountToWithdraw);
        (bool success, ) = msg.sender.call{value: amountToWithdraw / EXCHANGE_RATE}("");
        if (!success) revert EthTransferFailed();
    }

    // --------------------------------------------
    //  Cross-Chain Transfers
    // --------------------------------------------

    /**
     * @notice Burns SETH from account
     * @dev Function restricted to SETHAdapter only; debits msg.sender on srcChain
     */
    function burn(address from, uint256 amount) external onlyAdapter returns (bool) {
        _burn(from, amount);
        return true;
    }

    /**
     * @notice Releases ETH collateral for cross-chain SETH transfers
     * @dev Function restricted to SETHAdapter only; releases ethAmount from srcChain
     */
    function releaseCollateral(uint256 sethAmount) external onlyAdapter {
        uint256 ethAmount = sethAmount / EXCHANGE_RATE;
        (bool success, ) = msg.sender.call{value: ethAmount}("");
        if (!success) revert EthTransferFailed();
    }

    /**
     * @notice Mints SETH to account
     * @dev Function restricted to SETHAdapter only; credits msg.sender on dstChain
     */
    function mint(address to, uint256 amount) external onlyAdapter returns (bool) {
        _mint(to, amount);
        return true;
    }

    /**
     * @notice Receives ETH collateral from cross-chain SETH transfers
     * @dev Function restricted to SETHAdapter only; receives ethAmount on dstChain without minting SETH equivalent
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

    /// @notice Total SETH supply on deployment chain
    /// @dev Does not account for total SETH supply across all chains
    function sethSupply() external view returns (uint256) {
        return totalSupply();
    }

    /// @notice ETH collateral balance that backs SETH supply
    /// @dev Does not account for total ETH collateral across all chains
    function ethCollateral() external view returns (uint256) {
        return address(this).balance - accruedFees;
    }

    /// @notice Get the ETH value of currently accrued fees
    /// @dev Does not account for total fees accrued in ETH across all chains
    function accruedFeesInEth() external view returns (uint256) {
        return accruedFees;
    }

    // --------------------------------------------
    //  Check ETH:SETH collateralization
    // --------------------------------------------

    /// @notice Check if the 1:100 collateral ratio is maintained
    /// @dev Uses ethCollateral() (balance minus accrued fees) so fee liabilities are excluded from backing
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