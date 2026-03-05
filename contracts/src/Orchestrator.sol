// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

/**
 * @title Orchestrator
 * @notice Admin relay owned by Multisig; wraps privileged actions and predefines possible updates
 * @dev Orchestrator is granted relevant admin roles for SETHAdapter, AppRegistry and PBRManager to 
 * maintain local storage properties and perform key maintenance actions.
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @custom:security-contact security@islalabs.co
 */
contract Orchestrator {
	address public multisig;

    address public immutable SETH_ADAPTER;
    address public immutable APP_REGISTRY;
    address public immutable PBR_MANAGER;

    // ------------------------------------------
	//  Events/Errors
	// ------------------------------------------

    event SafeUpdated(address indexed prev, address indexed next);
    event NewChainAdded(uint32 indexed eid, uint64 chainId);
    event NewAppAdded(address indexed deployerAddress, address beneficiaryAddress);
    event SethAdapterAdded(uint32 indexed eid, address newSethAdapter);
    event PbrScriptUpdated(address indexed pbrManager);

    error ZeroAddress();
    error Unauthorized();

    // ------------------------------------------
	//  Access Control
	// ------------------------------------------

    /// @notice Restricts actions to multisig
	modifier onlyMultisig() {
		if (msg.sender != multisig) revert Unauthorized();
		_;
	}

    // ------------------------------------------
	//  Initialization
	// ------------------------------------------

    constructor(
        address _multisig, 
        address _sethAdapter, 
        address _appRegistry, 
        address _pbrManager
    ) {
		if (
            _multisig == address(0) ||
            _sethAdapter == address(0) ||
            _appRegistry == address(0) ||
            _pbrManager == address(0)
        ) revert ZeroAddress();

        multisig = _multisig;

        SETH_ADAPTER = _sethAdapter;
        APP_REGISTRY = _appRegistry;
        PBR_MANAGER = _pbrManager;
	}

	receive() external payable { revert("ETH_DISABLED"); }
	fallback() external payable { revert("ETH_DISABLED"); }

    // ------------------------------------------
	//  AppRegistry Admin
	// ------------------------------------------



	// ------------------------------------------
	//  SETHAdapter Admin
	// ------------------------------------------



    // ------------------------------------------
	//  PBRManager Admin
	// ------------------------------------------

    

    // ------------------------------------------
	//  Orchestrator Admin
	// ------------------------------------------

    /// @notice Rotates multisig address
    function rotateMultisig(address newMultisig) external onlyMultisig {
		if (newMultisig == address(0)) revert ZeroAddress();

		emit SafeUpdated(multisig, newMultisig);
		multisig = newMultisig;
	}
}