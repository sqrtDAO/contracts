// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig, GetContractInfoResult} from "./DistributorV1.sol";

/// @title DistributionV1Factory
/// @notice Deploys DistributorV1 instances. Kept as a separate contract so FactoryV1
///         does not have to embed the distributor creation bytecode, keeping the
///         factory under the EIP-170 contract size limit.
contract DistributionV1Factory {
    event NewDistributor(address indexed distributor);

    /// @notice the only address allowed to create distributors through this contract
    address public factory;

    /// @notice (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) public creatorOf;

    /// to show latest on website
    /// there are block limitation to do this with events
    address[] private distributionList;

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == factory, "only factory");
    }

    function distributionListLength() external view returns (uint256) {
        return distributionList.length;
    }

    function getDistributionsInfo(uint256 _offset, uint256 _size)
        external
        view
        returns (AddressAndDistributionInfo[] memory result)
    {
        require(_offset <= distributionList.length && _size <= distributionList.length - _offset, "out of scope");
        result = new AddressAndDistributionInfo[](_size);
        for (uint256 i = 0; i < _size; i++) {
            result[i] = AddressAndDistributionInfo({
                info: DistributorV1(distributionList[_offset + i]).getContractInfo(),
                addr: distributionList[_offset + i]
            });
        }
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
        creatorOf[distributorAddress] = _creator;
        distributionList.push(distributorAddress);
        emit NewDistributor(distributorAddress);
    }
}

struct AddressAndDistributionInfo {
    GetContractInfoResult info;
    address addr;
}
