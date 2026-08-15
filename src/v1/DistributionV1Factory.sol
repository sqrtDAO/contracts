// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig} from "./DistributorV1.sol";

/// @title DistributionV1Factory
/// @notice Deploys DistributorV1 instances. Kept as a separate contract so FactoryV1
///         does not have to embed the distributor creation bytecode, keeping the
///         factory under the EIP-170 contract size limit.
contract DistributionV1Factory {
    /// @notice the only address allowed to create distributors through this contract
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

    /// @notice deploys a new DistributorV1 with `_creator` as its CREATOR
    /// @return distributorAddress address of the deployed distributor
    function createDistributor(address _creator, DistributorConfig memory _config)
        external
        onlyFactory
        returns (address distributorAddress)
    {
        distributorAddress = address(new DistributorV1(_creator, _config));
    }
}
