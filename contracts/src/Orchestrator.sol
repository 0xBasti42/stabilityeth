// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

/**
 * @title Orchestrator
 * @notice Admin relay owned by Multisig; wraps privileged actions and predefines possible updates
 * @dev Orchestrator is granted relevant admin roles for SETHAdapter, AppRegistry and PBRManager to 
 * maintain local storage properties and perform key maintenance actions.
 */
contract Orchestrator {
	address public multisig;

    address public immutable sethAdapter;
    address public immutable appRegistry;
    address public immutable pbrManager;

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

        sethAdapter = _sethAdapter;
        appRegistry = _appRegistry;
        pbrManager = _pbrManager;
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