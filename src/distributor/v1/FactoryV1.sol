// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1, Range} from "./DistributorV1.sol";
import {Hook} from "src/utils/Hook.sol";
import {EmissionFunction} from "src/utils/emission-function/EmissionFunction.sol";
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
        address _distributionToken,
        address _participationToken,
        uint256 _epochDuration,
        uint256 _startTimestamp,
        uint256 _minParticipation,
        uint256 _claimDelaySeconds,
        bool _allowFutureEpochParticipation,
        Hook memory _drainHook,
        EmissionFunction memory _emissionFunction,
        address _allowlistSigner,
        uint256 _allowlistDeadline,
        uint256 _participationAmountPerEpoch,
        Range calldata _participationRange
    ) external returns (address distributorAddress) {
        DistributorV1 distributor = new DistributorV1(
            _distributionToken,
            _participationToken,
            _epochDuration,
            _startTimestamp,
            protocolFeeInv,
            protocolFeeReceiver,
            _minParticipation,
            _claimDelaySeconds,
            _allowFutureEpochParticipation,
            _drainHook,
            _emissionFunction,
            _allowlistSigner,
            _allowlistDeadline
        );

        require(
            IERC20(_participationToken)
                .transferFrom(msg.sender, address(this), _participationAmountPerEpoch * _participationRange.length)
        );

        distributor.participate(_participationAmountPerEpoch, _participationRange, msg.sender, new bytes(0)); // msg.sender set as recipient so it can claim

        distributorAddress = address(distributor);
        emit NewDistributor(distributorAddress);
    }
}
