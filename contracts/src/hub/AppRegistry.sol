// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.34;

import { Initializable } from "@openzeppelin-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AppRegistry | StabilityETH
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @notice Centralized registry and verification process for dApps seeking to earn Performance Based Returns (PBR)
 * @dev Registration involves an onchain verification process, validating ownership of linked contracts per deployer,
 *      and filtering verifiedToken / verifiedTvl by a non-arbitrary minimumValue
 * @custom:experimental Turning TVL into an additional source of revenue for verified dApps | https://stability-eth.io/registry/
 * @custom:security-contact security@islalabs.co
 */
contract AppRegistry is Initializable {
    address orchestrator;
    address pbr_manager;

    // --------------------------------------------
    //  Configuration
    // --------------------------------------------

    // --------------------------------------------
    //  Events & Errors
    // --------------------------------------------

    error Unauthorized();
    error InvalidAddress();

    // --------------------------------------------
    //  Access Control
    // --------------------------------------------

    modifier onlyOrchestrator() {
        if (msg.sender != orchestrator) revert Unauthorized();
        _;
    }

    modifier onlyPbrManager() {
        if (msg.sender != pbr_manager) revert Unauthorized();
        _;
    }

    // --------------------------------------------
    //  Initialization
    // --------------------------------------------

    constructor() {
        _disableInitializers(); // locks implementation (only UpgradeableBeacon can update)
    }

    function initialize(
        address _orchestrator,
        address _pbrManager
    ) external initializer {
        if (_orchestrator == address(0) || _pbrManager == address(0)) revert InvalidAddress();

        orchestrator = _orchestrator;
        pbr_manager = _pbrManager;
    }

    receive() external payable {
        revert("DIRECT_ETH_DISABLED");
    }

    fallback() external payable {
        revert("DIRECT_ETH_DISABLED");
    }

    // --------------------------------------------
    //  Registration
    // --------------------------------------------

    // --------------------------------------------
    //  Verification
    // --------------------------------------------

    // --------------------------------------------
    //  Internal
    // --------------------------------------------
}
