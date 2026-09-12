// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {TokenV1, Allocation} from "./TokenV1.sol";

/// @title TokenV1Factory
/// @notice Deploys TokenV1 instances. Kept as a separate contract so FactoryV1
///         does not have to embed the token creation bytecode, keeping the
///         factory under the EIP-170 contract size limit.
contract TokenV1Factory {
    event NewToken(address indexed tokenAddress);

    /// @notice the only address allowed to create tokens through this contract
    address public factory;

    /// @notice (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) public creatorOf;

    /// to show latest on website
    /// there are block limitation to do this with events
    address[] private tokenList;

    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        require(msg.sender == factory, "only factory");
    }

    function tokenListLength() external view returns (uint256) {
        return tokenList.length;
    }

    function getTokens(uint256 _offset, uint256 _size) external view returns (address[] memory result) {
        require(_offset <= tokenList.length && _size <= tokenList.length - _offset, "out of scope");
        result = new address[](_size);
        for (uint256 i = 0; i < _size; i++) {
            result[i] = tokenList[_offset + i];
        }
    }

    /// @notice sets the factory allowed to deploy through this contract (callable once)
    function setFactory(address _factory) external {
        require(factory == address(0) && _factory != address(0), "already set");
        factory = _factory;
    }

    /// @notice deploys a new TokenV1
    /// @param _creator the address that requested the token creation (the end user, not this factory)
    /// @return tokenAddress address of the deployed token
    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations, address _creator)
        external
        onlyFactory
        returns (address tokenAddress)
    {
        tokenAddress = address(new TokenV1(_name, _symbol, _allocations));
        creatorOf[tokenAddress] = _creator;
        tokenList.push(tokenAddress);
        emit NewToken(tokenAddress);
    }
}
