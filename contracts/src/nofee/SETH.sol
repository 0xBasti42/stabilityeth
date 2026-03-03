// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title SETH - StabilityETH
 * @notice Minted and burned at a 100:1 ratio with ETH
 */
contract SETH is ERC20Permit {
    uint256 public constant EXCHANGE_RATE = 100;
    uint256 private constant BPS_DENOMINATOR = 10000;

    error EthTransferFailed();

    constructor() ERC20("StabilityETH", "SETH") ERC20Permit("StabilityETH") {}

    /// @notice Relay ETH deposits
    receive() external payable {
        deposit();
    }

    /// @notice Mint SETH at 100:1 ratio to ETH deposits
    function deposit() public payable {
        _mint(msg.sender, msg.value * EXCHANGE_RATE);
    }

    /// @notice Burn SETH and withdraw ETH at 100:1 ratio
    function withdraw(uint256 sethAmount) external {
        _burn(msg.sender, sethAmount);
        
        (bool success, ) = msg.sender.call{value: sethAmount / EXCHANGE_RATE}("");
        if (!success) revert EthTransferFailed();
    }

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