// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

struct Hook {
    address contractAddress;
    bytes callData;
}
event HookFailure(bytes returnData);
