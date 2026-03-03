// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { FunctionsClient } from "@chainlink/functions/v1_3_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/functions/v1_0_0/libraries/FunctionsRequest.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title PBRTreasury
 * @notice Receives ETH fees from SETH transfers
 * @dev Minimal implementation - can be extended for fee distribution
 */
contract PBRTreasury is FunctionsClient, ReentrancyGuard {
    using FunctionsRequest for FunctionsRequest.Request;

    address public appRegistry;
    address public pbrManager;
    address private protocol;

    // ------------------------------------------
    //  Config
    // ------------------------------------------

    enum Cycle {One, Two, Three, Four, Five, Six, Seven}

    mapping(Cycle => uint256) public scalars;
    
    uint256 public lastDistributionTimestamp;
    uint256 public constant PROTOCOL_FEE_BPS = 750; // 0.0225% total
    uint256 private constant BPS_DENOMINATOR = 10000;

    uint256 public pendingProtocolFees;

    // ------------------------------------------
    //  Events & Errors
    // ------------------------------------------

    event EthReceived(address indexed from, uint256 amount);
    event ProtocolTransferFailed(uint256 protocolFee);
    event ScalarCommitted(Cycle indexed cycle, uint256 scalar, uint256 timestamp);
    event DistributionTriggered(uint256 totalAmount, uint256 protocolFee, uint256 distributed);

    error Unauthorized();
    error InvalidAddress();
    error ProtocolTransferFailed();

    // ------------------------------------------
    //  Access Control
    // ------------------------------------------

    modifier onlyManager() {
        if (msg.sender != pbrManager) revert Unauthorized();
        _;
    }

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor(address _pbrManager, address _protocol) {
        if (_pbrManager == address(0) || _protocol == address(0)) revert InvalidAddress();

        pbrManager = _pbrManager;
        protocol = _protocol;
    }

    /// @notice Receive ETH from SETH fees
    receive() external payable {
        // Calculate shares
        uint256 protocolShare = (msg.value * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 pbrShare = msg.value - protocolShare;
        
        // Take protocolShare
        if (protocolShare > 0 && protocol != address(0)) {
            (bool success, ) = protocol.call{value: protocolShare}("");
            if (!success) {
                pendingProtocolFees += protocolShare;
                emit ProtocolTransferFailed(protocolShare);
            }
        }
        
        // pbrShare remains in this contract for TVL-based distribution
        emit EthReceived(msg.sender, pbrShare);
    }

    /// @notice Recover protocol fees in event of non-blocking failure
    function recoverProtocolFees() external {
        uint256 pending = pendingProtocolFees;
        if (pending == 0) return;
        
        pendingProtocolFees = 0;
        (bool success, ) = protocol.call{value: pending}("");
        if (!success) revert ProtocolTransferFailed();
    }

    // ------------------------------------------
    //  Distribute ETH as PBR
    // ------------------------------------------

    function getData() external onlyManager {
        - Uses Chainlink Functions
        - Fetches USD price for all ERC/SPL token addresses in AppRegistry + ETH + SOL

        - Scans all contract addresses in AppRegistry for balances of tokens that were included
        in the AppSet entry for the same deployer
        - Creates verifiedTvl output mapped to each beneficiary address

        - Sums verifiedTvl for all beneficiaries
        - uTvl / TVL = user's proportional share of scalar
    }

    /// @notice Commit scalar for the current cycle (called by PBRManager)
    /// @param cycle The current cycle (0-6 mapping to One-Seven)
    function commitScalar(uint8 cycle) external onlyManager {
        Cycle currentCycle = Cycle(cycle);

        // Probably need some kind of cooldown logic to rate limit the Chainlink Functions requests, 
        // then we can allow anyone to call the function & also automate it
        
        // Fetch or calculate scalar for this cycle
        // TODO: Integrate with oracle/CGSM for real scalar data
        uint256 scalar = _calculateScalar(currentCycle);
        
        cycleScalars[currentCycle] = scalar;
        
        emit ScalarCommitted(currentCycle, scalar, block.timestamp);
        
        // Special logic on Cycle Four: trigger distribution
        if (currentCycle == Cycle.Four) {
            _triggerDistribution();
        }
    }

    // ------------------------------------------
    //  Internal Functions
    // ------------------------------------------

    /// @dev Calculate scalar for the given cycle
    /// @param cycle The cycle to calculate scalar for
    function _calculateScalar(Cycle cycle) internal view returns (uint256) {
        // TODO: Implement actual scalar calculation
        // This could involve:
        // - Fetching performance data from AppRegistry
        // - Querying CGSM (Chainlink General Service Module)
        // - Computing weighted averages based on TVL
        
        // Placeholder: return cycle index as scalar
        return uint256(cycle) + 1;
    }
    
    /// @dev Trigger distribution on Cycle Four
    function _triggerDistribution() internal {
        uint256 totalBalance = address(this).balance;
        if (totalBalance == 0) return;
        
        // Calculate protocol fee (10%)
        uint256 protocolFee = (totalBalance * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 distributable = totalBalance - protocolFee;
        
        lastDistributionTimestamp = block.timestamp;
        
        // TODO: Implement actual distribution logic
        // - Query AppRegistry for verified applications
        // - Calculate share per application based on scalars
        // - Send ETH to each application or bridge via Wormhole/Stargate
        
        emit DistributionTriggered(totalBalance, protocolFee, distributable);
    }

    // ------------------------------------------
    //  External View
    // ------------------------------------------

    /// @notice Get the current ETH balance held by the treasury
    function balance() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice Get scalar for a specific cycle
    function getScalar(Cycle cycle) external view returns (uint256) {
        return scalars[cycle];
    }
}