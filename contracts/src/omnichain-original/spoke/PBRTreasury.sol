// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/interfaces/OApp.sol";

/**
 * @title PBRTreasury | StabilityETH
 * @notice Enables omnichain PBR distribution
 */
contract PBRTreasury is OApp, ReentrancyGuard {
    ~PBR Claims~
    1. Deployer/Beneficiary on dstChain can call SETHOutbound to request ETH from PBRTreasury
    2. SETHOutbound sends message to SETHInbound. SETHInbound checks msg.sender against AppRegistry
    3. If valid, SETHInbound relays claim request to PBRTreasury
    4. PBRTreasury sends ETH to beneficiary via Stargate
    5. SETHOutbound returns success message to msg.sender, via SETHInbound
}