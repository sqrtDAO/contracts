// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IEmissionFunction} from "src/utils/emission-function/IEmissionFunction.sol";

struct EmissionFunction {
    IEmissionFunction emissionContract;
    bytes curveConfig;
}
