// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookFailure} from "src/utils/Hook.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

interface IEmissionFunction {
    function rewardOf(
        uint256 _initialReward,
        uint256 _currentEpoch
    ) external returns (uint256 reward);
}
