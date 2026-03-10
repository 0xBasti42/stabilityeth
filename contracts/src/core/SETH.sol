// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { DynamicFee } from "@core/base/DynamicFee.sol";

/**
 * @title SETH | StabilityETH
 * @notice Omnichain SETH is minted and burned at a 100:1 ratio with ETH; provides Performance Based Returns (PBR) to verified applications
 * @dev Turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 * @dev Inherits DynamicFee for proprietary fee calculation which uses tiered exponential decay to determine feeBps output for volumeEth input
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @custom:security-contact security@islalabs.co
 */
contract SETH is ERC20, ERC20Permit, ReentrancyGuard, DynamicFee {
    address public immutable SETH_ADAPTER;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    /// @notice Maintains 1:100 collateralization between ETH and SETH
    uint256 public constant EXCHANGE_RATE = 100;

    /// @notice Standardized basis points denominator
    uint256 private constant BPS_DENOMINATOR = 10000;

    /// @notice Ringfenced account keeping for PBR fees; collected lazily during PBR distribution
    uint256 public accruedFees;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event Deposit(address indexed dst, uint256 ethAmount, uint256 sethAmount);
    event Withdrawal(address indexed src, uint256 sethAmount, uint256 ethAmount);

    event FeesAccrued(address indexed from, uint256 amountAdded, uint256 totalOutstanding);

    event BridgedOut(address indexed from, uint256 sethAmount, uint256 ethAmount);
    event BridgedIn(address indexed to, uint256 sethAmount, uint256 ethAmount);

    error InvalidAddress();
    error InvalidAmount();
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

    constructor(address _sethAdapter, address _chainlinkEthUsd)
        ERC20("StabilityETH", "SETH")
        ERC20Permit("StabilityETH")
        DynamicFee(_chainlinkEthUsd)
    {
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
     * @dev Dynamic fee on deposit is accrued for PBR based on transaction volume; cross-chain mints via adapter have no fee
     */
    function deposit() public payable {
        uint256 feeBps = calculateDynamicFee(msg.value);
        uint256 fee = (msg.value * feeBps) / BPS_DENOMINATOR;
        uint256 amountIn = msg.value - fee;

        accruedFees += fee;
        uint256 sethAmount = amountIn * EXCHANGE_RATE;
        _mint(msg.sender, sethAmount);

        if (fee > 0) {
            emit FeesAccrued(msg.sender, fee, accruedFees);
        }
        emit Deposit(msg.sender, msg.value, sethAmount);
    }

    /**
     * @notice Burns SETH and withdraws ETH at 100:1 ratio
     * @dev Rounds down to nearest multiple of EXCHANGE_RATE; dust stays with caller. Dynamic fee on withdraw is accrued for PBR.
     */
    function withdraw(uint256 sethAmount) external nonReentrant {
        // Round down to maintain 1:100 collateralization; dust stays with sender (up to 99 wei)
        uint256 amountToWithdraw = (sethAmount / EXCHANGE_RATE) * EXCHANGE_RATE;
        uint256 ethAmount = amountToWithdraw / EXCHANGE_RATE;
        uint256 feeBps = calculateDynamicFee(ethAmount);
        uint256 fee = (ethAmount * feeBps) / BPS_DENOMINATOR;
        uint256 amountOut = ethAmount - fee;

        accruedFees += fee;
        _burn(msg.sender, amountToWithdraw);

        (bool success, ) = msg.sender.call{value: amountOut}("");
        if (!success) revert EthTransferFailed();

        if (fee > 0) {
            emit FeesAccrued(msg.sender, fee, accruedFees);
        }
        emit Withdrawal(msg.sender, amountToWithdraw, amountOut);
    }

    // --------------------------------------------
    //  Cross-Chain Transfers
    // --------------------------------------------

    /**
     * @notice Burns SETH from account and releases ETH collateral to caller (SETHAdapter)
     * @dev Function restricted to SETHAdapter only; used for cross-chain sends. Debits msg.sender on srcChain and releases collateral.
     */
    function burn(address from, uint256 amount) external onlyAdapter returns (bool) {
        uint256 ethAmount = amount / EXCHANGE_RATE;
        _burn(from, amount);

        (bool success, ) = msg.sender.call{value: ethAmount}("");
        if (!success) revert EthTransferFailed();

        emit BridgedOut(from, amount, ethAmount);
        return true;
    }

    /**
     * @notice Receives ETH collateral and mints SETH to account (SETHAdapter)
     * @dev Function restricted to SETHAdapter only; used for cross-chain receives. Deposits collateral on dstChain and credits recipient.
     */
    function mint(address to, uint256 amount) external payable onlyAdapter returns (bool) {
        if (amount < EXCHANGE_RATE) revert InvalidAmount();

        amount = (amount / EXCHANGE_RATE) * EXCHANGE_RATE;
        uint256 expectedEth = amount / EXCHANGE_RATE;
        if (msg.value != expectedEth) revert InvalidAmount();

        _mint(to, amount);

        emit BridgedIn(to, amount, expectedEth);
        return true;
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