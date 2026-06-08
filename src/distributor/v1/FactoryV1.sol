// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {DistributorV1} from "./DistributorV1.sol";
import {Hook} from "src/utils/Hook.sol";

contract FactoryV1 {
    event NewDistributor(address indexed distributor);

    function createDistributor(
        address _token,
        address _baseToken,
        uint256 _epochDuration,
        uint256 _startTimestamp,
        Hook memory _drainHook
    ) external returns (address distributorAddress) {
        DistributorV1 distributor = new DistributorV1(
            _token,
            _baseToken,
            _epochDuration,
            _startTimestamp,
            _drainHook
        );

        distributorAddress = address(distributor);
        emit NewDistributor(distributorAddress);
    }
}
