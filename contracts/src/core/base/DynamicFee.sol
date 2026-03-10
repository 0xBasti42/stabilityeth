// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.34;

import { AggregatorV3Interface } from "@core/base/interfaces/AggregatorV3Interface.sol";
import { SD59x18, exp, sd } from "@prb-math/src/SD59x18.sol";

/**
 * @title DynamicFee with Chainlink integration to enable stable fee tiers
 * @notice Dynamic fee uses tiered exponential decay with configurable parameters to output a variable fee rate at different transaction volumes
 * @dev Full formula: ϕ(v) = f_min + (ϕ_start - f_min) ⋅ e^(−α ⋅ (v−v_start) / κ)
 * @author Isla Labs (Tom Jarvis | 0xBasti42)
 * @custom:security-contact security@islalabs.co
 */
abstract contract DynamicFee {
    /// @notice Chainlink ETH-USD price feed
    address public immutable CHAINLINK_ETH_USD;

    /// @notice Feed decimals for CHAINLINK_ETH_USD
    uint8 public immutable FEED_DECIMALS;

    /// @notice Fallback ETH-USD price for testnet
    uint256 public immutable FALLBACK_ETH_PRICE;

    // ------------------------------------------
    //  Dynamic Fee Constants
    // ------------------------------------------

    uint256 internal constant FEE_MIN_BPS = 100; // should be 060 for 0.60%

    uint256 internal constant FEE_START_TIER_1 = 500; // should be 200 for 2.00%
    uint256 internal constant FEE_START_TIER_2 = 481;
    uint256 internal constant FEE_START_TIER_3 = 322;
    uint256 internal constant FEE_START_TIER_4 = 123;

    uint256 internal constant ALPHA_TIER_1 = 100;
    uint256 internal constant ALPHA_TIER_2 = 120;
    uint256 internal constant ALPHA_TIER_3 = 50;
    uint256 internal constant ALPHA_TIER_4 = 100;

    uint256 internal constant TIER_1_THRESHOLD_USD = 0;
    uint256 internal constant TIER_2_THRESHOLD_USD = 500;
    uint256 internal constant TIER_3_THRESHOLD_USD = 5000;
    uint256 internal constant TIER_4_THRESHOLD_USD = 50000;

    uint256 internal constant SCALE_PARAMETER = 1000;

    // ------------------------------------------
    //  Initialization
    // ------------------------------------------

    constructor(address _chainlinkEthUsd) {
        CHAINLINK_ETH_USD = _chainlinkEthUsd;
        FALLBACK_ETH_PRICE = 3000000000; // 6 decimals

        uint8 _dec = 8;
        if (CHAINLINK_ETH_USD != address(0)) {
            try AggregatorV3Interface(CHAINLINK_ETH_USD).decimals() returns (uint8 d) {
                _dec = d;
            } catch {}
        }
        FEED_DECIMALS = _dec;
    }

    // ------------------------------------------
    //  Fee Calculation
    // ------------------------------------------

    /**
     * @notice Dynamic fee with exponential decay
     * @param volumeEth Volume in ETH (wei)
     * @return feeBps Fee in basis points
     */
    function calculateDynamicFee(uint256 volumeEth) public view returns (uint256 feeBps) {
        // Fetch ETH price
        uint256 ethPriceUsd = _ethPriceUsd();

        // Standardize volume (v) in usd
        uint256 volumeUsd = (volumeEth * ethPriceUsd) / (1 ether * 1e6);

        // Get decay factor (a), vStartUsd (v_start), feeStart (feeRate_start) based on volume tier
        (uint256 alpha, uint256 vStartUsd, uint256 feeStart) = _getTierParameters(volumeUsd);

        // Calculate +difference between volume (v) and tier's starting volume (v_start)
        uint256 volumeDiff = volumeUsd > vStartUsd ? volumeUsd - vStartUsd : 0;

        // Build the exponent input and compute the exponential term
        uint256 exponent = (alpha * volumeDiff) / SCALE_PARAMETER;
        uint256 expValue = _calculateExponentialDecay(exponent);

        // Map decay into fee range
        uint256 feeRange = feeStart - FEE_MIN_BPS;
        uint256 dynamicComponent = (feeRange * expValue) / 1 ether;

        // Final fee in bps
        uint256 result = FEE_MIN_BPS + dynamicComponent;
        return result < FEE_MIN_BPS ? FEE_MIN_BPS : result;
    }

    // ------------------------------------------
    //  Internal
    // ------------------------------------------

    /**
     * @notice Get tier parameters based on USD volume; volume is converted from ETH for stable fee tier values (v_start)
     * @dev Returns static variables from cache so that volume (v) is the only dynamic input
     * @param volumeUsd Volume in USD
     * @return alpha Decay factor for fee tier
     * @return vStartUsd Starting volume threshold for fee tier
     * @return feeStart Precomputed fee (bps) at v_start for fee tier
     */
    function _getTierParameters(uint256 volumeUsd) internal pure returns (uint256 alpha, uint256 vStartUsd, uint256 feeStart) {
        if (volumeUsd <= TIER_2_THRESHOLD_USD) return (ALPHA_TIER_1, TIER_1_THRESHOLD_USD, FEE_START_TIER_1);
        if (volumeUsd <= TIER_3_THRESHOLD_USD) return (ALPHA_TIER_2, TIER_2_THRESHOLD_USD, FEE_START_TIER_2);
        if (volumeUsd <= TIER_4_THRESHOLD_USD) return (ALPHA_TIER_3, TIER_3_THRESHOLD_USD, FEE_START_TIER_3);
        return (ALPHA_TIER_4, TIER_4_THRESHOLD_USD, FEE_START_TIER_4);
    }

    /**
	 * @notice Calculate e^(-x/1000) with 18-decimal precision
     * @dev Uses PRBMath SD59x18 to evaluate exp on the signed fixed-point input -x/1000
	 * @param x Unscaled exponent input
     * @return value The 1e18-scaled result of e^(-x/1000)
     */
    function _calculateExponentialDecay(uint256 x) internal pure returns (uint256 value) {
        if (x == 0) return 1 ether; // e^0 = 1
        if (x >= 10000) return 0;   // e^(-10) ≈ 0 (clamp for extreme values)

        // Convert to signed fixed-point and compute e^(-x/1000)
        SD59x18 negativeX = sd(-int256(x)) / sd(1000);
        SD59x18 result = exp(negativeX);

        return uint256(result.unwrap()); // 1e18-scaled
    }

    // ------------------------------------------
    //  ETH-USD Price Fetch
    // ------------------------------------------

    /// @notice Fetch ETH price (uses fallback on testnet)
    function _ethPriceUsd() internal view returns (uint256 ethPriceUsd) {
        if (CHAINLINK_ETH_USD == address(0)) return FALLBACK_ETH_PRICE;

        try AggregatorV3Interface(CHAINLINK_ETH_USD).latestRoundData()
            returns (uint80 roundId, int256 answer, uint256 /* startedAt */, uint256 updatedAt, uint80 answeredInRound)
        {
            if (answer > 0 && updatedAt != 0 && answeredInRound >= roundId) {
                uint8 dec = FEED_DECIMALS;
                if (dec >= 6) {
                    uint256 factor = 10 ** (uint256(dec) - 6);
                    return uint256(answer) / factor;
                } else {
                    uint256 factor = 10 ** (6 - uint256(dec));
                    return uint256(answer) * factor;
                }
            }
        } catch {}

        return FALLBACK_ETH_PRICE;
    }
}