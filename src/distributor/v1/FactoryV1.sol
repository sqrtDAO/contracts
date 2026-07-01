// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, DistributorConfig, Range} from "./DistributorV1.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

contract FactoryV1 is Ownable {
    event NewDistributor(address indexed distributor);

    uint256 protocolFeeInv;
    address protocolFeeReceiver;

    constructor(address _initialOwner) Ownable(_initialOwner) {}

    function setProtocolFeeInv(uint256 _protocolFeeInv) public onlyOwner {
        protocolFeeInv = _protocolFeeInv;
    }

    function setProtocolFeeReceiver(address _protocolFeeReceiver) public onlyOwner {
        protocolFeeReceiver = _protocolFeeReceiver;
    }

    function createDistributor(
        DistributorConfig memory _config,
        uint256 _participationAmountPerEpoch,
        Range calldata _participationRange
    ) external returns (address distributorAddress) {
        _config.protocolFeeInv = protocolFeeInv;
        _config.protocolFeeReceiver = protocolFeeReceiver;

        DistributorV1 distributor = new DistributorV1(_config);

        require(
            IERC20(_config.participationToken)
                .transferFrom(msg.sender, address(this), _participationAmountPerEpoch * _participationRange.length)
        );

        distributor.participate(_participationAmountPerEpoch, _participationRange, msg.sender, new bytes(0)); // msg.sender set as recipient so it can claim

        distributorAddress = address(distributor);
        emit NewDistributor(distributorAddress);
    }
}
