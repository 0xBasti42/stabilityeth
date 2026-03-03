// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import { FunctionsClient } from "@chainlink/functions/v1_3_0/FunctionsClient.sol";
import { FunctionsRequest } from "@chainlink/functions/v1_0_0/libraries/FunctionsRequest.sol";

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
contract AppRegistry is FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;
    
}