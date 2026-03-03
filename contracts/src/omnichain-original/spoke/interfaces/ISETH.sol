// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ISETH {
    function clearPendingFees() external returns (uint256);
    function pendingFeeRelay() external view returns (uint256);
}