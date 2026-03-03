// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISETHAdapter {
    function depositFor(address recipient) external payable returns (bool);
    function withdrawFor(address recipient, uint256 sethAmount) external;
    function relayBurnedFees(uint256 sethBurned) external;
}