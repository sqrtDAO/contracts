// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Hook, HookFailure} from "src/utils/Hook.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

/// @title Distributor
/// @notice Base template for distributor contracts that perform token transfers to recipients.
/// @dev Extend this contract for versioned implementations like `DistributorV1`.
contract DistributorV1 {
    IERC20 public immutable TOKEN;
    IERC20 public immutable BASE_TOKEN;
    uint256 public immutable EPOCH_DURATION;
    uint256 public immutable START_TIMESTAMP;
    Hook public drainHook;

    /**
     * @param _token address of token you want to distribute
     * @param _baseToken address of token contract receive in epochs when user participate
     * @param _epochDuration duration of each epoch (in seconds)
     * @param _startTimestamp time of first epoch starts
     * @param _drainHook contract calls this hook after epoch ends (on first claim)
     */
    constructor(
        address _token,
        address _baseToken,
        uint256 _epochDuration,
        uint256 _startTimestamp,
        Hook memory _drainHook
    ) {
        TOKEN = IERC20(_token);
        BASE_TOKEN = IERC20(_baseToken);
        EPOCH_DURATION = _epochDuration;
        START_TIMESTAMP = _startTimestamp;
        drainHook = _drainHook;
    }

    function _callDrainHook() internal returns (bytes memory) {
        // approve so drainHook contract can control distributor contract tokens
        BASE_TOKEN.approve(
            drainHook.contractAddress,
            BASE_TOKEN.balanceOf(address(this))
        );

        (bool success, bytes memory result) = drainHook.contractAddress.call(
            drainHook.callData
        );

        if (!success) {
            emit HookFailure(result);
        }

        require(success, "Distributor: hook call failed");
        return result;
    }
}
