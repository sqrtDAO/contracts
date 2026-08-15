// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {TokenV1, Allocation} from "./TokenV1.sol";

/// @title TokenV1Factory
/// @notice Deploys TokenV1 instances. Kept as a separate contract so FactoryV1
///         does not have to embed the token creation bytecode, keeping the
///         factory under the EIP-170 contract size limit.
contract TokenV1Factory {
    /// @notice the only address allowed to create tokens through this contract
    address public factory;

    modifier onlyFactory() {
        require(msg.sender == factory, "only factory");
        _;
    }

    /// @notice sets the factory allowed to deploy through this contract (callable once)
    function setFactory(address _factory) external {
        require(factory == address(0) && _factory != address(0), "already set");
        factory = _factory;
    }

    /// @notice deploys a new TokenV1
    /// @return tokenAddress address of the deployed token
    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations)
        external
        onlyFactory
        returns (address tokenAddress)
    {
        tokenAddress = address(new TokenV1(_name, _symbol, _allocations));
    }
}
