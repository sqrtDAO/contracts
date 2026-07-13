// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig, Range} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TokenV1, Allocation} from "./TokenV1.sol";

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;

    event NewDistributor(address indexed distributor);
    event NewToken(address indexed tokenAddress);

    uint256 public protocolFeeBps;
    address public protocolFeeReceiver;

    /// (contract => creator)
    /// @dev this can be used to check if contract address is a valid contract created by this factory and not somewhere else
    /// but it saves creator address instead of bool "just in case"
    mapping(address => address) creatorOf;

    constructor(address _initialOwner, uint256 _protocolFeeBps, address _protocolFeeReceiver) Ownable(_initialOwner) {
        protocolFeeBps = _protocolFeeBps;
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    function checkContractDeployedByThis(address _contractAddress) public view returns (bool) {
        return creatorOf[_contractAddress] != address(0);
    }

    function setProtocolFeeBps(uint256 _protocolFeeBps) public onlyOwner {
        protocolFeeBps = _protocolFeeBps;
    }

    function setProtocolFeeReceiver(address _protocolFeeReceiver) public onlyOwner {
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    /// @dev Make sure you give allowance to Factory contract before call this
    /// allowance to both participation token (for initial participation) and distribution token to transfer totalDistributionAmount to distribution contract
    function createDistributor(
        DistributorConfig memory _config,
        uint256 _participationAmountPerEpoch,
        Range calldata _participationRange
    ) external returns (address distributorAddress) {
        DistributorV1 distributor = new DistributorV1(address(this), protocolFeeBps, protocolFeeReceiver, _config);

        IERC20(_config.distributionToken)
            .safeTransferFrom(msg.sender, address(distributor), _config.totalDistributionAmount);

        uint256 initialParticipationAmount = _participationAmountPerEpoch * _participationRange.length;

        IERC20(_config.participationToken).safeTransferFrom(msg.sender, address(this), initialParticipationAmount);

        IERC20(_config.participationToken).approve(address(distributor), initialParticipationAmount);

        distributor.participate(_participationAmountPerEpoch, _participationRange, msg.sender, new bytes(0)); // msg.sender set as recipient so it can claim

        distributorAddress = address(distributor);
        creatorOf[distributorAddress] = msg.sender;
        emit NewDistributor(distributorAddress);
    }

    function createToken(string memory _name, string memory _symbol, Allocation[] memory _allocations)
        external
        payable
        returns (address tokenAddress)
    {
        // Deploy new token – the total supply goes straight to the creator (msg.sender)
        TokenV1 newToken = new TokenV1(_name, _symbol, _allocations);
        tokenAddress = address(newToken);
        emit NewToken(tokenAddress);
    }
}
