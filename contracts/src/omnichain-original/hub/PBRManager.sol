// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { AutomationCompatibleInterface } from "@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

interface IPBRTreasury {
    function commitScalar(uint8 cycle) external;
}

/**
 * @title PBRManager | StabilityETH
 * @notice Chainlink Automation-compatible contract for cycling PBR commits
 * @dev Integrates with Chainlink Automation to call commitScalar daily
 */
contract PBRManager is AutomationCompatibleInterface {
    IPBRTreasury public immutable pbrTreasury;

    // ------------------------------------------
    //  Config
    // ------------------------------------------

    enum Cycle {One, Two, Three, Four, Five, Six, Seven}
    
    uint256 public lastPerformTime;
    uint256 public constant CYCLE_INTERVAL = 1 days;
    
    Cycle public currentCycle;

    // ------------------------------------------
    //  Events & Errors
    // ------------------------------------------

    event CycleAdvanced(Cycle indexed newCycle, uint256 timestamp);

    error TooEarly();
    error InvalidTreasury();

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor(address _pbrTreasury) {
        if (_pbrTreasury == address(0)) revert InvalidTreasury();
        pbrTreasury = IPBRTreasury(_pbrTreasury);
        lastPerformTime = block.timestamp;
        currentCycle = Cycle.One;
    }

    // ------------------------------------------
    //  Chainlink Automation
    // ------------------------------------------

    /// @notice Chainlink Automation check function
    /// @dev Called off-chain to determine if performUpkeep should be called
    function checkUpkeep(bytes calldata /* checkData */)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp - lastPerformTime) >= CYCLE_INTERVAL;
        performData = ""; // No data needed
    }

    /// @notice Chainlink Automation perform function
    /// @dev Called by Chainlink Automation when checkUpkeep returns true
    function performUpkeep(bytes calldata /* performData */) external override {
        if ((block.timestamp - lastPerformTime) < CYCLE_INTERVAL) {
            revert TooEarly();
        }

        lastPerformTime = block.timestamp;
        
        // Advance cycle (wraps from Seven back to One)
        currentCycle = Cycle((uint8(currentCycle) + 1) % 7);
        
        // Call treasury with current cycle
        pbrTreasury.commitScalar(uint8(currentCycle));

        emit CycleAdvanced(currentCycle, block.timestamp);
    }

    /// @notice Get time until next cycle
    function timeUntilNextCycle() external view returns (uint256) {
        uint256 elapsed = block.timestamp - lastPerformTime;
        if (elapsed >= CYCLE_INTERVAL) return 0;
        return CYCLE_INTERVAL - elapsed;
    }
}