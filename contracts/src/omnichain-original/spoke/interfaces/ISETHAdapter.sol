// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISETHAdapter {
    function depositFor(address recipient) external payable;
    function withdrawFor(address recipient, uint256 sethAmount) external;
    function ringfenceFees(uint256 sethBurned) external returns (bool);
    function clearToMainnet() external payable;
    function pendingCollateral() external view returns (uint256);
}