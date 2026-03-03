// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

struct AppSet {
    address deployer;
    address beneficiary;
    uint16 chainId;
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
contract AppRegistry {
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
    //  Events
    // ------------------------------------------

    event AppRegistered(
        bytes32 indexed appId, 
        address indexed deployer, 
        address beneficiary, 
        uint8 chainId
    );
    event AppDeactivated(bytes32 indexed appId, address indexed by);
    event AppReactivated(bytes32 indexed appId, address indexed by);
    event BeneficiaryUpdated(bytes32 indexed appId, address oldBeneficiary, address newBeneficiary);
    event ChainSupportUpdated(uint8 indexed chainId, bool supported);

    // ------------------------------------------
    //  Errors
    // ------------------------------------------

    error InvalidAddress();
    error InvalidContracts();
    error UnsupportedChain(uint8 chainId);
    error AppAlreadyExists(bytes32 appId);
    error AppNotFound(bytes32 appId);
    error Unauthorized();
    error AppNotActive(bytes32 appId);
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

    /// @notice Simulate verification without state changes
    /// @return valid Whether verification would pass
    /// @return reason Human-readable failure reason (empty if valid)
    function simulateVerification(
        address deployer,
        address beneficiary,
        uint8 chainId,
        address[] calldata contracts,
        address[] calldata tokens
    ) external view returns (bool valid, string memory reason) {
        // Check deployer address
        if (deployer == address(0)) {
            return (false, "Invalid deployer address");
        }

        // Check beneficiary address
        if (beneficiary == address(0)) {
            return (false, "Invalid beneficiary address");
        }

        // Check chain support
        if (!supportedChains[chainId]) {
            return (false, "Unsupported chain ID");
        }

        // Must have at least one contract
        if (contracts.length == 0) {
            return (false, "At least one contract required");
        }

        // Check for zero addresses in contracts
        for (uint256 i = 0; i < contracts.length; i++) {
            if (contracts[i] == address(0)) {
                return (false, "Invalid contract address");
            }
        }

        // Check for zero addresses in tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) {
                return (false, "Invalid token address");
            }
        }

        // Check for duplicate contracts
        for (uint256 i = 0; i < contracts.length; i++) {
            for (uint256 j = i + 1; j < contracts.length; j++) {
                if (contracts[i] == contracts[j]) {
                    return (false, "Duplicate contract address");
                }
            }
        }

        // Check for duplicate tokens
        for (uint256 i = 0; i < tokens.length; i++) {
            for (uint256 j = i + 1; j < tokens.length; j++) {
                if (tokens[i] == tokens[j]) {
                    return (false, "Duplicate token address");
                }
            }
        }

        // Check if app already exists
        bytes32 appId = _computeAppId(deployer, chainId, contracts);
        if (_apps[appId].deployer != address(0)) {
            return (false, "App already registered");
        }

        return (true, "");
    }

    /// @notice Verify and register a new application
    /// @return appId The unique identifier for the registered app
    function verifyAndAdd(
        address deployer,
        address beneficiary,
        uint8 chainId,
        address[] calldata contracts,
        address[] calldata tokens
    ) external returns (bytes32 appId) {
        // Only deployer can register their own app
        if (msg.sender != deployer) revert Unauthorized();

        // Validate addresses
        if (deployer == address(0) || beneficiary == address(0)) {
            revert InvalidAddress();
        }

        // Validate chain
        if (!supportedChains[chainId]) {
            revert UnsupportedChain(chainId);
        }

        // Validate contracts
        if (contracts.length == 0) {
            revert InvalidContracts();
        }

        // Validate no zero addresses and no duplicates
        _validateAddressArray(contracts);
        _validateAddressArray(tokens);

        // Compute app ID
        appId = _computeAppId(deployer, chainId, contracts);

        // Check not already registered
        if (_apps[appId].deployer != address(0)) {
            revert AppAlreadyExists(appId);
        }

        // Store the app
        AppSet storage app = _apps[appId];
        app.deployer = deployer;
        app.beneficiary = beneficiary;
        app.chainId = chainId;
        app.isActive = true;

        // Copy arrays
        for (uint256 i = 0; i < contracts.length; i++) {
            app.contracts.push(contracts[i]);
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            app.tokens.push(tokens[i]);
        }

        // Track app ID
        appIds.push(appId);
        deployerApps[deployer].push(appId);

        emit AppRegistered(appId, deployer, beneficiary, chainId);
    }

    // ------------------------------------------
    //  Management
    // ------------------------------------------

    /// @notice Update beneficiary address (only deployer)
    /// @param appId The app to update
    /// @param newBeneficiary The new beneficiary address
    function updateBeneficiary(bytes32 appId, address newBeneficiary) external {
        AppSet storage app = _apps[appId];
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (msg.sender != app.deployer) revert Unauthorized();
        if (newBeneficiary == address(0)) revert InvalidAddress();

        address oldBeneficiary = app.beneficiary;
        app.beneficiary = newBeneficiary;

        emit BeneficiaryUpdated(appId, oldBeneficiary, newBeneficiary);
    }

    /// @notice Deactivate an app (only deployer)
    /// @param appId The app to deactivate
    function deactivate(bytes32 appId) external {
        AppSet storage app = _apps[appId];
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (msg.sender != app.deployer) revert Unauthorized();
        if (!app.isActive) revert AppNotActive(appId);

        app.isActive = false;

        emit AppDeactivated(appId, msg.sender);
    }

    /// @notice Reactivate an app (only deployer)
    /// @param appId The app to reactivate
    function reactivate(bytes32 appId) external {
        AppSet storage app = _apps[appId];
        
        if (app.deployer == address(0)) revert AppNotFound(appId);
        if (msg.sender != app.deployer) revert Unauthorized();
        if (app.isActive) revert AppNotActive(appId); // Already active

        app.isActive = true;

        emit AppReactivated(appId, msg.sender);
    }

    // ------------------------------------------
    //  View Functions
    // ------------------------------------------

    /// @notice Get full app data
    /// @param appId The app ID to query
    /// @return The AppSet struct
    function getApp(bytes32 appId) external view returns (AppSet memory) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId];
    }

    /// @notice Check if an app is verified and active
    /// @param appId The app ID to check
    /// @return True if app exists and is active
    function isVerified(bytes32 appId) external view returns (bool) {
        return _apps[appId].deployer != address(0) && _apps[appId].isActive;
    }

    /// @notice Get total number of registered apps
    /// @return The count of all registered apps
    function appCount() external view returns (uint256) {
        return appIds.length;
    }

    /// @notice Get all apps by a deployer
    /// @param deployer The deployer address
    /// @return Array of app IDs
    function getAppsByDeployer(address deployer) external view returns (bytes32[] memory) {
        return deployerApps[deployer];
    }

    /// @notice Get contracts for an app (for TVL measurement)
    /// @param appId The app ID
    /// @return Array of contract addresses
    function getContracts(bytes32 appId) external view returns (address[] memory) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId].contracts;
    }

    /// @notice Get tokens for an app
    /// @param appId The app ID
    /// @return Array of token addresses
    function getTokens(bytes32 appId) external view returns (address[] memory) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId].tokens;
    }

    /// @notice Get beneficiary for an app (for PBR distribution)
    /// @param appId The app ID
    /// @return The beneficiary address
    function getBeneficiary(bytes32 appId) external view returns (address) {
        if (_apps[appId].deployer == address(0)) revert AppNotFound(appId);
        return _apps[appId].beneficiary;
    }

    // ------------------------------------------
    //  Internal Functions
    // ------------------------------------------

    /// @dev Compute deterministic app ID from deployer, chain, and contracts
    function _computeAppId(
        address deployer,
        uint8 chainId,
        address[] calldata contracts
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(deployer, chainId, contracts));
    }

    /// @dev Validate array has no zero addresses or duplicates
    function _validateAddressArray(address[] calldata addrs) internal pure {
        for (uint256 i = 0; i < addrs.length; i++) {
            if (addrs[i] == address(0)) revert InvalidAddress();
            for (uint256 j = i + 1; j < addrs.length; j++) {
                if (addrs[i] == addrs[j]) revert DuplicateAddress();
            }
        }
    }
}