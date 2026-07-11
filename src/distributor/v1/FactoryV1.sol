// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig, Range} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract FactoryV1 is Ownable {
    using SafeERC20 for IERC20;

    event NewDistributor(address indexed distributor);

    uint256 protocolFeeBps;
    address protocolFeeReceiver;

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    function setProtocolFeeBps(uint256 _protocolFeeBps) public onlyOwner {
        protocolFeeBps = _protocolFeeBps;
    }

    function setProtocolFeeReceiver(address _protocolFeeReceiver) public onlyOwner {
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    function createDistributor(
        DistributorConfig memory _config,
        uint256 _participationAmountPerEpoch,
        Range calldata _participationRange
    ) external returns (address distributorAddress) {
        _config.protocolFeeBps = protocolFeeBps;
        _config.protocolFeeReceiver = protocolFeeReceiver;

        DistributorV1 distributor = new DistributorV1(_config);

        IERC20(_config.participationToken)
            .safeTransferFrom(msg.sender, address(this), _participationAmountPerEpoch * _participationRange.length);

        distributor.participate(_participationAmountPerEpoch, _participationRange, msg.sender, new bytes(0)); // msg.sender set as recipient so it can claim

        distributorAddress = address(distributor);
        emit NewDistributor(distributorAddress);
    }
}
