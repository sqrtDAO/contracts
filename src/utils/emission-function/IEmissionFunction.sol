// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IEmissionFunction {
    function calculate(bytes calldata _curveConfig, uint256 _epochNumber) external view returns (uint256 reward);

    /// @notice Calculates sum of rewards of all epochs in range [0, _numEpochs)
    /// @dev Must not loop over epochs (number of epochs can be huge), use a closed form formula instead
    /// @param _curveConfig encoded curve configuration
    /// @param _numEpochs number of epochs to sum up
    /// @return total sum of calculate(_curveConfig, i) for i in [0, _numEpochs)
    function calculateTotal(bytes calldata _curveConfig, uint256 _numEpochs) external view returns (uint256 total);
}
