// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TokenV1, Allocation} from "./TokenV1.sol";

/**
 * @title TokenFactory
 * @notice A simple launchpad: anyone can deploy a new Token by paying a creation fee.
 * @dev The fee is collected by the factory owner. Excess ETH is refunded.
 */
contract TokenFactory {
    event TokenCreated(address indexed tokenAddress, string name, string symbol, address indexed creator);

    /**
     * @notice Create a new token.
     * @param _name         Token name (e.g. "MyToken")
     * @param _symbol       Token symbol (e.g. "MTK")
     * @param _allocations  allocations
     */
    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations)
        external
        payable
        returns (address tokenAddress)
    {
        // Deploy new token – the total supply goes straight to the creator (msg.sender)
        TokenV1 newToken = new TokenV1(_name, _symbol, _allocations);
        tokenAddress = address(newToken);
        emit TokenCreated(tokenAddress, _name, _symbol, msg.sender);
    }
}
