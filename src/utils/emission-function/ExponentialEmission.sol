// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

/// f(x) = a * b^x
/// where a is initial value and b is curve factor
/// if b > 1 its a exponential growth
/// if 1 > b > 0 its a exponential decay
contract ExponentialEmission is IEmissionFunction {
    /// higher internal precision for `calculateTotal`: the geometric series divides by the tiny
    /// (1 - r) factor, so a low precision representation of r would get its truncation error
    /// amplified by 1 / (1 - r)
    uint256 private constant TOTAL_SCALE = 1e27;

    function calculate(bytes calldata _curveConfig, uint256 _epochNumber) external pure returns (uint256 reward) {
        ExponentialEmissionConfig memory config = abi.decode(_curveConfig, (ExponentialEmissionConfig));

        if (_epochNumber == 0) return config.initialAmount;
        if (config.numerator == 0) return 0;
        if (config.numerator == config.denominator) return config.initialAmount;

        reward = config.initialAmount;
        uint256 num = config.numerator;
        uint256 den = config.denominator;
        uint256 exp = _epochNumber;

        // For exponential decay (numerator < denominator)
        if (num < den) {
            while (exp > 0 && reward > 0) {
                if (exp & 1 == 1) {
                    reward = (reward * num) / den;
                }

                exp >>= 1;
                if (exp > 0) {
                    // Scale before squaring to prevent overflow
                    uint256 scale = 1e18;
                    // Convert to scaled representation: num/den becomes num*scale/den
                    uint256 scaledNum = (num * scale) / den;
                    uint256 scaledDen = scale;

                    // Now square in the scaled space
                    num = (scaledNum * scaledNum) / scale;
                    den = (scaledDen * scaledDen) / scale;
                }
            }
        } else {
            // For growth (numerator > denominator)
            while (exp > 0) {
                if (exp & 1 == 1) {
                    reward = (reward * num) / den;
                }

                exp >>= 1;
                if (exp > 0) {
                    // Scale before squaring
                    uint256 scale = 1e18;
                    uint256 scaledNum = (num * scale) / den;
                    uint256 scaledDen = scale;

                    num = (scaledNum * scaledNum) / scale;
                    den = (scaledDen * scaledDen) / scale;
                }
            }
        }

        return reward;
    }

    /// @notice sum of rewards of epochs [0, _numEpochs) using the geometric series formula (O(log _numEpochs))
    /// @dev sum = initialAmount * (1 - r^N) / (1 - r) for decay and
    ///      initialAmount * (r^N - 1) / (r - 1) for growth, where r = numerator / denominator.
    ///      Computed in 1e27 fixed point internally, so the result matches the ideal sum of the
    ///      curve up to sub-wei rounding; per epoch `calculate` itself truncates a few wei per
    ///      multiplication, so the real paid-out total can only be smaller (never larger).
    ///      Reverts on overflow, which means the total does not fit in uint256 and can never be
    ///      funded anyway.
    function calculateTotal(bytes calldata _curveConfig, uint256 _numEpochs) external pure returns (uint256 total) {
        if (_numEpochs == 0) return 0;

        ExponentialEmissionConfig memory config = abi.decode(_curveConfig, (ExponentialEmissionConfig));
        uint256 initial = config.initialAmount;

        // epoch 0 always gives `initialAmount` and every other epoch gives 0
        if (config.numerator == 0) return initial;
        // r == 1: every epoch gives the same reward
        if (config.numerator == config.denominator) return initial * _numEpochs;

        uint256 q = (config.numerator * TOTAL_SCALE) / config.denominator;
        bool isDecay = config.numerator < config.denominator;

        // growth, but factor is so close to 1 that it rounds down to exactly 1 in fixed point
        if (!isDecay && q == TOTAL_SCALE) return initial * _numEpochs;

        uint256 p = _powFixedPoint(q, _numEpochs, TOTAL_SCALE);

        if (isDecay) {
            // decay: sum = initial * (TOTAL_SCALE - p) / (TOTAL_SCALE - q)
            return initial * (TOTAL_SCALE - p) / (TOTAL_SCALE - q);
        }

        // growth: sum = initial * (p - TOTAL_SCALE) / (q - TOTAL_SCALE)
        return initial * (p - TOTAL_SCALE) / (q - TOTAL_SCALE);
    }

    /// @notice q^exp in `scale` fixed point (q is already scaled by `scale`), binary exponentiation
    function _powFixedPoint(uint256 q, uint256 exp, uint256 scale) private pure returns (uint256 result) {
        result = scale;
        uint256 base = q;
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * base) / scale;
            }
            exp >>= 1;
            if (exp > 0) {
                base = (base * base) / scale;
            }
        }
    }
}

/// curve factor = numerator / denominator
/// example:
///  1005 and 1000 means 1.005
struct ExponentialEmissionConfig {
    uint256 initialAmount;
    uint256 numerator; // e.g., 101 for 1% growth
    uint256 denominator; // e.g., 100
}
