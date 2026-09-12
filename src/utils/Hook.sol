// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

struct Hook {
    address contractAddress;
    bytes callData;
}

event HookFailure(bytes data);

library HookLib {
    error HookReverted(bytes data);

    /// @notice reverts on error
    function call(Hook memory hook) internal returns (bytes memory returnData) {
        (bool success, bytes memory returnData_) = hook.contractAddress.call(hook.callData);
        if (!success) revert HookReverted(returnData_);
        returnData = returnData_;
    }

    /// @notice emits on error (no revert)
    function tryCall(Hook memory hook) internal returns (bool success, bytes memory returnData) {
        (success, returnData) = hook.contractAddress.call(hook.callData);
        if (!success) emit HookFailure(returnData);
    }
}
