// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { RateLimiter } from "@layerzerolabs/oapp-evm/contracts/oapp/utils/RateLimiter.sol";

interface ISETHAdapterAdmin {
    function addSethAdapter(uint32 _eid, address _adapter, uint192 _limit, uint64 _window) external;
    function setRateLimits(RateLimiter.RateLimitConfig[] calldata _rateLimitConfigs) external;
    function resetRateLimits(uint32[] calldata _eids) external;
    function pause() external;
    function unpause() external;
    function setMinTransferAmount(uint256 _min) external;
}

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

    /// @notice Add a new SETHAdapter for a destination chain
    function addSethAdapter(uint32 _eid, address _adapter, uint192 _limit, uint64 _window) external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).addSethAdapter(_eid, _adapter, _limit, _window);
        emit SethAdapterAdded(_eid, _adapter);
    }

    /// @notice Set rate limits per destination chain
    function setSethAdapterRateLimits(RateLimiter.RateLimitConfig[] calldata _rateLimitConfigs) external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).setRateLimits(_rateLimitConfigs);
    }

    /// @notice Reset rate limit in-flight amounts for given chains
    function resetSethAdapterRateLimits(uint32[] calldata _eids) external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).resetRateLimits(_eids);
    }

    /// @notice Pause outbound SETH sends
    function pauseSethAdapter() external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).pause();
    }

    /// @notice Unpause outbound SETH sends
    function unpauseSethAdapter() external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).unpause();
    }

    /// @notice Set minimum SETH transfer amount
    function setSethAdapterMinTransferAmount(uint256 _min) external onlyMultisig {
        ISETHAdapterAdmin(SETH_ADAPTER).setMinTransferAmount(_min);
    }

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