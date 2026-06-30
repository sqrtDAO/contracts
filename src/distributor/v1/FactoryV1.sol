// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1} from "./DistributorV1.sol";
import {Hook} from "src/utils/Hook.sol";
import {EmissionFunction} from "src/utils/emission-function/EmissionFunction.sol";

contract FactoryV1 {
    event NewDistributor(address indexed distributor);

    function createDistributor(
        address _token,
        address _baseToken,
        uint256 _epochDuration,
        uint256 _startTimestamp,
        uint256 _protocolFeeInv,
        address _protocolFeeReceiver,
        uint256 _minParticipation,
        uint256 _claimDelaySeconds,
        bool _allowFutureEpochParticipation,
        Hook memory _drainHook,
        EmissionFunction memory _emissionFunction
    ) external returns (address distributorAddress) {
        DistributorV1 distributor = new DistributorV1(
            _token,
            _baseToken,
            _epochDuration,
            _startTimestamp,
            _protocolFeeInv,
            _protocolFeeReceiver,
            _minParticipation,
            _claimDelaySeconds,
            _allowFutureEpochParticipation,
            _drainHook,
            _emissionFunction
        );

        distributorAddress = address(distributor);
        emit NewDistributor(distributorAddress);
    }
}
