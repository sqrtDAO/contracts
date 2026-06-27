// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TokenV1} from "./TokenV1.sol";

/**
 * @title TokenFactory
 * @notice A simple launchpad: anyone can deploy a new Token by paying a creation fee.
 * @dev The fee is collected by the factory owner. Excess ETH is refunded.
 */
contract TokenFactory {
    event TokenCreated(
        address indexed tokenAddress, string name, string symbol, uint256 totalSupply, address indexed creator
    );

    constructor() {}

    /**
     * @notice Create a new token.
     * @param _name         Token name (e.g. "MyToken")
     * @param _symbol       Token symbol (e.g. "MTK")
     * @param _totalSupply  Total supply in smallest unit (18 decimals)
     * @return tokenAddress Address of the newly created token
     */
    function createToken(string calldata _name, string calldata _symbol, uint256 _totalSupply)
        external
        payable
        returns (address tokenAddress)
    {
        // Deploy new token – the total supply goes straight to the creator (msg.sender)
        TokenV1 newToken = new TokenV1(_name, _symbol, _totalSupply, msg.sender);
        tokenAddress = address(newToken);
        emit TokenCreated(tokenAddress, _name, _symbol, _totalSupply, msg.sender);
    }
}
