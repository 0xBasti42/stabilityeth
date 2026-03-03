// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { FunctionsClient } from "@chainlink/functions/v1_3_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/functions/v1_0_0/libraries/FunctionsRequest.sol";

struct AppSet {
    address deployer;
    address beneficiary;
    uint8 chainId;
    address[] contracts;
    address[] tokens;
    bool isActive;
}

struct Blocklist {
    address deployer;
}

/**
 * @title AppRegistry | StabilityETH
 * @notice Stores verified applications, PBR beneficiaries, and the contracts to scan for verifiedTvl
 * @dev The PBR algorithm turns TVL into an additional source of revenue for verified applications | https://stability-eth.io/registry/
 */
contract AppRegistry is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;

    // ------------------------------------------
    //  State
    // ------------------------------------------

    /// @notice Mapping from app ID to AppSet
    mapping(bytes32 => AppSet) private _apps;
    
    /// @notice Track all registered app IDs
    bytes32[] public appIds;
    
    /// @notice Track deployer's apps
    mapping(address => bytes32[]) public deployerApps;

    /// @notice Supported chain IDs for cross-chain verification
    mapping(uint8 => bool) public supportedChains;

    // ------------------------------------------
    //  Events & Errors
    // ------------------------------------------

    event AppRegistered(bytes32 indexed appId, address indexed deployer, address beneficiary, uint8 chainId);
    event AppDeactivated(bytes32 indexed appId, address indexed by);
    event AppReactivated(bytes32 indexed appId, address indexed by);
    event BeneficiaryUpdated(bytes32 indexed appId, address oldBeneficiary, address newBeneficiary);
    event ChainSupportUpdated(uint8 indexed chainId, bool supported);

    error InvalidAddress();
    error InvalidContracts();
    error UnsupportedChain(uint8 chainId);
    error AppAlreadyExists(bytes32 appId);
    error AppNotFound(bytes32 appId);
    error Unauthorized();
    error AppNotActive(bytes32 appId);
    error AppIsActive(bytes32 appId);
    error DuplicateAddress();

    // ------------------------------------------
    //  Constructor
    // ------------------------------------------

    constructor(uint8[] memory initialChains) {
        for (uint256 i = 0; i < initialChains.length; i++) {
            supportedChains[initialChains[i]] = true;
            emit ChainSupportUpdated(initialChains[i], true);
        }
    }

    // ------------------------------------------
    //  Verification
    // ------------------------------------------

    function simulateVerification {
        - External request to execute Chainlink Functions verification
    }

    function verifyAndRegister {
        - External request to execute a Chainlink Functions verification
        - Data mapping to AppSet struct
    }

    // ------------------------------------------
    //  Internal Functions
    // ------------------------------------------

    function _computeAppId(
        address deployer,
        uint8 chainId,
        address[] calldata contracts
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, chainId, contracts));
    }

    function _validateAddressArray(address[] calldata addrs) internal pure {
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == address(0)) revert InvalidAddress();
            for (uint256 j = i + 1; j < addrs.length; j++) {
                if (addrs[i] == addrs[j]) revert DuplicateAddress();
            }
        }
    }

    // ------------------------------------------
    //  Management
    // ------------------------------------------

    function updateBeneficiary(bytes32 appId, address newBeneficiary) external {
        AppSet storage app = _apps[appId];
        if (msg.sender != app.deployer) revert Unauthorized();
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (newBeneficiary == address(0)) revert InvalidAddress();

        address oldBeneficiary = app.beneficiary;
        app.beneficiary = newBeneficiary;

        emit BeneficiaryUpdated(appId, oldBeneficiary, newBeneficiary);
    }

    function deactivate(bytes32 appId) external {
        AppSet storage app = _apps[appId];
        if (msg.sender != app.deployer) revert Unauthorized();
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (!app.isActive) revert AppNotActive(appId);

        app.isActive = false;

        emit AppDeactivated(appId, msg.sender);
    }

    function reactivate(bytes32 appId) external {
        AppSet storage app = _apps[appId];
        if (msg.sender != app.deployer) revert Unauthorized();
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (app.isActive) revert AppIsActive(appId);

        app.isActive = true;

        emit AppReactivated(appId, msg.sender);
    }

    function addToBlocklist(address deployer) external {
        - Simple call to add a deployer address to the Blocklist struct
        - Blocklist should be checked whenever a deployer address tries to update an AppSet
    }

    // ------------------------------------------
    //  View Functions
    // ------------------------------------------

    function getAppsByDeployer(address deployer) external view returns (bytes32[] memory) {
        return deployerApps[deployer];
    }

    function getAppContracts(bytes32 appId) external view returns (address[] memory) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId].contracts;
    }

    function getAppTokens(bytes32 appId) external view returns (address[] memory) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId].tokens;
    }

    function checkVerifiedTvl(bytes32 appId) {
        - External request to simulate current verifiedTvl value of contracts[]
        - Include comparison against totalVerifiedTvl to demonstrate PBR distribution
    }
}