// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IMintableBurnable } from "@layerzerolabs/oft-evm/contracts/interfaces/IMintableBurnable.sol";
import { ISETHAdapter } from "./interfaces/ISETHAdapter.sol";

/**
 * @title SETH | StabilityETH
 * @notice Minted and burned at a 100:1 ratio with ETH, provides Performance Based Returns (PBR)
 * @dev The PBR algorithm turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 */
contract SETH is ERC20Permit, ReentrancyGuard, IMintableBurnable {
    address public immutable pbrTreasury;
    ISETHAdapter public immutable adapter;

    uint256 public constant EXCHANGE_RATE = 100;
    uint256 public constant TRANSFER_FEE_BPS = 30;
    uint256 private constant BPS_DENOMINATOR = 10000;

    uint256 public spokeCirculation;
    uint256 public accruedFees;
    uint256 public constant FEE_SWEEP_THRESHOLD = 0.01 ether;

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    event FeesAccrued(address indexed from, uint256 amountAdded, uint256 totalOutstanding);
    event FeeSwept(uint256 ethSwept, uint256 treasuryBalance);
    event SpokeDeposit(uint256 ethAmount, uint256 sethMinted);
    event SpokeWithdraw(uint256 sethBurned, uint256 ethReleased);

    error InvalidAddress();
    error Unauthorized();
    error EthTransferFailed();

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

    constructor(address _pbrTreasury, address _adapter) ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {
        if (_pbrTreasury == address(0) || _adapter == address(0)) revert InvalidAddress();
        pbrTreasury = _pbrTreasury;
        adapter = ISETHAdapter(_adapter);
    }

    // --------------------------------------------
    //  Collateral Exchange
    // --------------------------------------------

    /// @notice Relay ETH deposits
    receive() external payable {
        deposit();
    }

    /// @notice Mint SETH at 100:1 ratio to ETH deposits
    function deposit() public payable {
        uint256 sethAmount = msg.value * EXCHANGE_RATE;

        _mint(msg.sender, sethAmount);

        if (msg.sender == address(adapter)) { 
            spokeCirculation += sethAmount;
            emit SpokeDeposit(msg.value, sethAmount);
        }
    }

    /// @notice Burn SETH and withdraw ETH at 100:1 ratio
    function withdraw(uint256 sethAmount) external nonReentrant {
        _burn(msg.sender, sethAmount);

        (bool success, ) = msg.sender.call{value: sethAmount / EXCHANGE_RATE}("");
        if (!success) revert EthTransferFailed();

        if (msg.sender == address(adapter) && success) { 
            spokeCirculation -= sethAmount;
            emit SpokeWithdraw(sethAmount, ethAmount);
        }
    }

    // --------------------------------------------
    //  Native Bridging
    // --------------------------------------------

    /// @notice IMintableBurnable handles native bridging from SETHAdapter (no collateral movements)
    function mint(address _to, uint256 _amount) external onlyAdapter returns (bool) {
        _mint(_to, _amount);

        spokeCirculation += _amount;
        emit SpokeDeposit(msg.value, _amount);

        return true;
    }

    /// @notice IMintableBurnable handles native bridging from SETHAdapter (no collateral movements)
    function burn(address _from, uint256 _amount) external onlyAdapter returns (bool) {
        _burn(_from, _amount);

        spokeCirculation -= _amount;
        emit SpokeWithdraw(sethAmount, _amount);
        
        return true;
    }

    // --------------------------------------------
    //  Mainnet Fee Handling
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

    // --------------------------------------------
    //  Omnichain Fee Handling
    // --------------------------------------------

    /// @notice Ringfence ETH for fees collected on spoke chains
    /// @dev Called by adapter when spoke notifies of burned transfer fees
    function ringfenceFees(uint256 sethAmount) external onlyAdapter {
        // Burn SETH from adapter's locked balance
        _burn(adapter, sethAmount);
        spokeCirculation -= sethAmount;
        
        // Ringfence underlying ETH as fees
        uint256 ethAmount = sethAmount / EXCHANGE_RATE;
        accruedFees += ethAmount;
        
        emit FeesAccrued(adapter, ethAmount, accruedFees);
        
        // Auto-sweep if threshold reached
        if (accruedFees >= FEE_SWEEP_THRESHOLD) {
            _sweepFees();
        }
    }

    // --------------------------------------------
    //  Fee Sweeping
    // --------------------------------------------

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
    //  View Functions
    // --------------------------------------------

    /// @notice Total SETH supply across all chains
    function totalSystemSupply() external view returns (uint256) {
        return totalSupply();  // Mainnet supply includes locked spoke supply
    }

    /// @notice SETH circulating on mainnet only
    function hubChainCirculation() external view returns (uint256) {
        return totalSupply() - spokeCirculation;
    }

    /// @notice SETH circulating on spoke chains
    function spokeChainCirculation() external view returns (uint256) {
        return spokeCirculation;
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