// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

interface IEmissionFunction {
    function calculate(
        bytes calldata _curveConfig,
        uint256 _epochNumber
    ) external view returns (uint256 reward);
}
